import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_channel.dart';

/// The one channel nem opens, named so it is recognisable in the dashboard's
/// realtime inspector. One channel carrying every table rather than one per
/// table: the tables are all subscribed and unsubscribed together, and a single
/// topic is a single join to keep track of.
const _topic = 'nem-sync';

/// The only implementation of [SyncChannel]: `supabase_flutter`, spoken to
/// directly (ADR 0002).
///
/// Nothing here decides anything. It opens a channel, binds every synced table
/// to it, and rings the bell — it does not read the payload, does not touch the
/// database and does not know what a task is. The payload is discarded on
/// purpose; `sync_channel.dart` has the argument, and the short form is that a
/// socket is neither ordered by the clock the cursor is built on nor complete
/// after a drop, so the row it carries is worth strictly less than the pull it
/// prompts.
///
/// ## What this needs on the backend
///
/// Realtime is off for a new table until it is added to the `supabase_realtime`
/// publication — see `supabase/migrations`. RLS still applies to the stream, so
/// the account (ADR 0003) sees its rows and the anon key sees nothing; the
/// Supabase client keeps the socket's token in step with the session on its own,
/// so there is no auth wiring here.
class SupabaseSyncChannel implements SyncChannel {
  SupabaseSyncChannel(this.client, {required this.tables});

  final SupabaseClient client;

  /// The table names to listen on — `defaultSyncedTables`, so registering a
  /// table stays the whole job of adding it to sync.
  final List<String> tables;

  RealtimeChannel? _channel;

  @override
  Future<void> open(void Function() onChanged) async {
    if (_channel != null) return;
    final channel = client.channel(_topic);
    for (final table in tables) {
      channel.onPostgresChanges(
        // Inserts, updates and deletes alike. nem's deletes are soft, so a
        // tombstone arrives here as an update anyway, and the three are the
        // same event to a doorbell.
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        // The payload goes nowhere, deliberately. See [SyncChannel].
        callback: (_) => onChanged(),
      );
    }
    channel.subscribe((status, error) {
      // A rejoin after a dropped socket arrives here as another `subscribed`,
      // and is worth a pull for the same reason the first one is: nothing was
      // listening a moment ago. That is a property of `realtime_client` worth
      // naming, because the drop-and-reconnect behaviour rests on it — the join
      // push keeps its `receive('ok')` hooks across a `resend`, so every rejoin
      // runs this callback again rather than only the first join.
      //
      // Nothing is done about the other statuses, and two of them are worse
      // than a socket that is merely down. `channelError` also carries the
      // verdict that the *replication* setup failed after the join succeeded —
      // a table missing from the `supabase_realtime` publication, or a token
      // RLS refuses — which is a channel that says `subscribed` and then
      // delivers nothing, and a binding mismatch unsubscribes the channel for
      // good. Neither recovers on its own.
      //
      // Reacting here would mean a reconnect loop written against a client that
      // already has one, so the recovery is the coarser one nem already has: a
      // background closes the channel and the next foreground opens a new one,
      // and in between the foreground trigger and the retry timer sync exactly
      // as they did before realtime existed. A dead subscription costs latency
      // and never a row — `sync_channel.dart` has why.
      if (status == RealtimeSubscribeStatus.subscribed) onChanged();
    });
    _channel = channel;
  }

  @override
  Future<void> close() async {
    final channel = _channel;
    if (channel == null) return;
    _channel = null;
    await client.removeChannel(channel);
  }
}
