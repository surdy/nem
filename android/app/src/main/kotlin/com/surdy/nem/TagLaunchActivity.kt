package com.surdy.nem

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * The scheme every code nem writes carries: `nem://t/<uuid>` (ADR 0009).
 *
 * Matched case-insensitively, because a URI scheme is case-insensitive and a
 * tag written by something other than nem may well shout it.
 */
internal const val SCAN_URI_SCHEME = "nem"

/**
 * Where Android delivers a tag tapped while nem is closed or in the background
 * (#9), and nothing else.
 *
 * It holds no UI and no Flutter engine: it reads the URI off the dispatched
 * intent, hands it to [MainActivity] and finishes. That shape is forced rather
 * than chosen. From Android 17 (API 37), with `targetSdk` above 36, an activity
 * receiving an NFC dispatch must declare
 * `android:permission="android.permission.DISPATCH_NFC_MESSAGE"`, and once it
 * does, only the NFC system service may start it — so it cannot be the
 * launcher, cannot be started from `adb`, and cannot be started by a test
 * (ADR 0009).
 *
 * A second `FlutterActivity` would have been the other way to do this, and
 * would have been wrong: two Flutter engines means two copies of the app's
 * state, two drift connections and two navigators, for a screen that exists for
 * a few milliseconds.
 *
 * Two platform behaviours this deliberately does not try to work around:
 *
 * - From Android 17 an app in the stopped state — never launched by the user,
 *   or force-stopped — receives no NFC intents at all. A tag cannot be nem's
 *   first launch, and nothing an app can do changes that.
 * - From Android 16 the user is asked, once, whether NFC may launch this app,
 *   and a "no" is permanent. The scan screen says so and offers the system
 *   screen that takes it back; see `MainActivity`'s `preference`.
 */
class TagLaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // The intent filter already guarantees the scheme, so this is belt and
        // braces against ever being started by anything else.
        val uri = intent?.data
        if (uri != null && SCAN_URI_SCHEME.equals(uri.scheme, ignoreCase = true)) {
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    data = uri
                    // Resume the task nem is already in rather than start a
                    // second one, and deliver the URI to the instance that is
                    // already there: CLEAR_TOP with MainActivity's singleTop
                    // launch mode is what turns this into an onNewIntent rather
                    // than a second MainActivity with a second copy of the
                    // app's state.
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    )
                },
            )
        }

        // Always, and before anything is drawn: this activity is a doorway.
        finish()
    }
}
