import 'package:nem/src/sync/sync_channel.dart';

/// A realtime subscription a test drives by hand.
///
/// The seam `RealtimeSync` is written against, standing in for the socket the
/// way `FakeSyncTransport` stands in for PostgREST — and for the same reason:
/// there is no Docker, no Supabase CLI and no project on the machine this suite
/// runs on, so the only honest way to exercise a dropped and regained
/// connection is to make dropping it a method call.
///
/// It models the three things about a real channel that the code has to be
/// right about:
///
/// * a join rings the bell ([open] and [reconnect]), because the real one
///   reports `RealtimeSubscribeStatus.subscribed` and anything at all could
///   have changed while nothing was listening;
/// * a socket that is down delivers nothing and says nothing ([drop]) — rows
///   changed while it is down are simply absent from the stream, and no amount
///   of waiting produces them;
/// * nothing it delivers carries a row. [deliverChange] takes no payload
///   because [SyncChannel] cannot express one, which is the whole design.
class FakeSyncChannel implements SyncChannel {
  void Function()? _onChanged;

  /// Whether the socket is up. Opening brings it up; [drop] takes it down
  /// without telling the listener, which is what a socket does.
  bool isConnected = false;

  int opens = 0;
  int closes = 0;

  /// Whether [open] has been called without a matching [close] — what "the
  /// subscription is torn down when the app backgrounds" is asserted on.
  bool get isOpen => _onChanged != null;

  @override
  Future<void> open(void Function() onChanged) async {
    opens++;
    _onChanged = onChanged;
    isConnected = true;
    // The join itself is a nudge.
    onChanged();
  }

  @override
  Future<void> close() async {
    closes++;
    _onChanged = null;
    isConnected = false;
  }

  /// The backend reports a change, and the socket is up to carry it.
  void deliverChange() {
    if (!isConnected) return;
    _onChanged?.call();
  }

  /// Connectivity goes. The channel is still "open" as far as the app knows —
  /// this is a dead socket, not a teardown — and every [deliverChange] while it
  /// is down goes nowhere at all.
  void drop() => isConnected = false;

  /// Connectivity comes back and the channel rejoins, which the real client
  /// reports as another `subscribed` and which rings the bell again.
  void reconnect() {
    if (_onChanged == null) return;
    isConnected = true;
    _onChanged!();
  }
}
