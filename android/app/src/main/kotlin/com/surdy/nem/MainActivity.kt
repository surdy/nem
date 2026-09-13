package com.surdy.nem

import android.content.ActivityNotFoundException
import android.content.Intent
import android.nfc.NfcAdapter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** The channel `PlatformTagLaunchGateway` talks on. */
private const val CHANNEL = "nem/tag_launch"

/**
 * nem's only Flutter activity, and the only one that holds an engine.
 *
 * Beyond hosting Flutter it does one job: it answers for the tags Android read
 * while nem was not looking (#9). `nfc_manager` reads no launch intent at all —
 * there is no `NDEF_DISCOVERED` or `onNewIntent` handling anywhere in it — so
 * the whole of the launch path is here and in [TagLaunchActivity].
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /**
     * A tapped URI nothing has asked for yet.
     *
     * Cold launch delivers the tag long before Dart exists, so the URI waits
     * here to be pulled rather than being pushed at a listener that is not
     * there. Pulled exactly once, so a rebuilt engine cannot replay a tap.
     */
    private var pendingUri: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (pendingUri == null) pendingUri = scanUriOf(intent)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler(::onMethodCall)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        // Without this, getIntent() keeps answering with the intent that
        // launched the activity, and every later reader of it — this class
        // included — silently reprocesses the first tag for as long as the
        // process lives. Reportedly the single most common NFC bug there is.
        setIntent(intent)
        super.onNewIntent(intent)

        val uri = scanUriOf(intent) ?: return
        val channel = this.channel
        // A tap that arrives before Dart is listening is a cold launch in all
        // but name, and waits to be pulled like one.
        if (channel == null) pendingUri = uri else channel.invokeMethod("tagLaunched", uri)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeLaunchUri" -> {
                val uri = pendingUri
                pendingUri = null
                // Consume the intent as well, so an activity recreated by a
                // rotation does not read the same tap back out of it. Replaced
                // only when there was a tag in it: a notification tap's intent
                // is somebody else's to read.
                if (uri != null) setIntent(Intent(Intent.ACTION_MAIN))
                result.success(uri)
            }
            "preference" -> result.success(tagLaunchPreference())
            "showPreferenceScreen" -> {
                showPreferenceScreen()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The `nem://` URI [intent] carries, or null when it carries none. */
    private fun scanUriOf(intent: Intent?): String? {
        val data = intent?.data ?: return null
        if (!SCAN_URI_SCHEME.equals(data.scheme, ignoreCase = true)) return null
        return data.toString()
    }

    /**
     * Whether the user has let NFC launch nem (Android 16, API 36).
     *
     * "unsupported" wherever the question cannot be asked — no NFC hardware, or
     * an Android that never prompts — because there is nothing to tell anybody
     * about on those devices.
     */
    private fun tagLaunchPreference(): String {
        if (Build.VERSION.SDK_INT < 36) return "unsupported"
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return "unsupported"
        return try {
            when {
                !adapter.isTagIntentAppPreferenceSupported -> "unsupported"
                adapter.isTagIntentAllowed -> "allowed"
                else -> "disallowed"
            }
        } catch (_: UnsupportedOperationException) {
            // Documented for devices without the NFC feature, which a null
            // adapter usually catches first.
            "unsupported"
        }
    }

    /**
     * Opens the system screen where a permanent "no" can be taken back.
     *
     * The prompt itself is the OS's and is shown once, ever, so this screen is
     * the only route back from it (ADR 0009).
     */
    private fun showPreferenceScreen() {
        if (Build.VERSION.SDK_INT < 36) return
        try {
            startActivity(Intent(NfcAdapter.ACTION_CHANGE_TAG_INTENT_PREFERENCE))
        } catch (_: ActivityNotFoundException) {
            // A device that does not ship the screen is a device where the
            // setting it changes does not exist either.
        }
    }
}
