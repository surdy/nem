import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_settings.dart';

/// Where a magic link comes back to.
///
/// The same custom scheme the tags carry (ADR 0009), on a host of its own:
/// `nem://t/<uuid>` resolves a target and `nem://login-callback/` finishes a
/// sign-in, and neither can be mistaken for the other. Reusing the scheme means
/// one registration per platform rather than two.
///
/// This string is also what has to be listed under **Authentication → URL
/// Configuration → Redirect URLs** in the Supabase dashboard; see
/// `supabase/README.md`.
const nemAuthRedirect = 'nem://login-callback/';

/// Owns the lifetime of the one Supabase instance.
///
/// **Not** a gateway over the Supabase API (ADR 0002). Callers get the real
/// [SupabaseClient] back and speak PostgREST and GoTrue on it directly —
/// nothing here wraps, translates or re-exposes a single call. What it owns is
/// the one thing a caller cannot: `Supabase.initialize` is a process-wide
/// singleton that may be called once, and nem's base URL and anon key are
/// editable settings, so something has to dispose the old instance and stand up
/// a new one when they change. That is a lifecycle, not an abstraction, and
/// deleting this class would not make the app any more portable — it would just
/// mean the settings screen could not be used twice.
class SupabaseConnection {
  SupabaseClient? _client;

  /// The settings the live instance was built from, so re-opening with the same
  /// ones is free.
  SyncSettings? _openedFor;

  /// The live client, or null when nem has no backend configured.
  SupabaseClient? get client => _client;

  /// Brings the client into line with [settings], and returns it.
  ///
  /// Returns null — having torn down anything that was open — when the settings
  /// are incomplete or the URL is not usable. That is the ordinary state of a
  /// fresh install, and every caller is expected to handle it by doing nothing
  /// at all (ADR 0001).
  Future<SupabaseClient?> open(SyncSettings settings) async {
    if (!settings.isConfigured) {
      await close();
      return null;
    }
    if (_client != null && _openedFor == settings) return _client;

    await close();
    final instance = await Supabase.initialize(
      url: settings.normalisedUrl!,
      // The parameter is `publishableKey` since supabase_flutter 2.17;
      // `anonKey` is the same field under a deprecated name. A self-hosted
      // instance still issues a JWT-shaped anon key and Supabase Cloud now
      // issues an `sb_publishable_...` one — both go here, and the settings
      // field takes either.
      publishableKey: settings.anonKey.trim(),
      // PKCE, the default, is what makes the magic link safe to hand to the
      // system browser: the code that comes back is useless without the
      // verifier this process kept.
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
    _openedFor = settings;
    return _client = instance.client;
  }

  /// Tears the instance down, leaving the stored session on disk — closing the
  /// connection is not signing out.
  Future<void> close() async {
    if (_client == null) return;
    _client = null;
    _openedFor = null;
    await Supabase.instance.dispose();
  }
}

/// Sends the magic link (PLAN.md — Sync: "email magic link").
///
/// One call, made directly on the client, which is the whole point of ADR 0002.
/// `shouldCreateUser` is left at its default so the very first sign-in creates
/// the single account (ADR 0003); the README's last step is to switch signups
/// off in the dashboard afterwards, which is what stops it being the *second*
/// account too.
Future<void> sendMagicLink(SupabaseClient client, String email) => client.auth
    .signInWithOtp(email: email.trim(), emailRedirectTo: nemAuthRedirect);
