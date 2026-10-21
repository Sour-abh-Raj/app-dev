import 'dart:async';
import 'dart:math' as math;

import '../../core/errors.dart';
import 'outbox.dart';

typedef OpHandler = Future<void> Function(OutboxOp op);

/// Drains the outbox (O2): on app start, on reconnect, and after each enqueue.
/// Transient errors back off with jitter; permanent errors are parked as
/// `failed` and surfaced in the UI — nothing is silently dropped.
class SyncEngine {
  SyncEngine({
    required this.outbox,
    required this.handlers,
    required this.isOnline,
    math.Random? rng,
    this.onPermanentFailure,
  }) : _rng = rng ?? math.Random();

  final Outbox outbox;
  final Map<String, OpHandler> handlers;
  final Future<bool> Function() isOnline;
  final void Function(OutboxOp op, String error)? onPermanentFailure;
  final math.Random _rng;

  Future<void>? _running;
  Timer? _timer;
  bool _again = false;

  /// Single-flight: concurrent calls share one drain; a call during a drain
  /// schedules exactly one more pass.
  Future<void> drain() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    final f = _drainLoop().whenComplete(() => _running = null);
    _running = f;
    return f;
  }

  Future<void> _drainLoop() async {
    do {
      _again = false;
      await _drainOnce();
    } while (_again);
    _scheduleNext();
  }

  Future<void> _drainOnce() async {
    if (!await isOnline()) return;
    for (final op in outbox.due()) {
      final handler = handlers[op.kind];
      if (handler == null) {
        await _fail(op, 'unknown op kind ${op.kind}');
        continue;
      }
      try {
        await handler(op);
        await outbox.complete(op);
      } on CapReachedError catch (e) {
        // Not a failure of the data: park until the allowance resets.
        await outbox.retryLater(op, e.retryAfter, e.message);
      } on PermanentError catch (e) {
        await _fail(op, e.message);
      } on TransientError catch (e) {
        await outbox.retryLater(
          op,
          e.retryAfter ?? backoff(op.attempts, rng: _rng),
          e.message,
        );
        if (e is OfflineError) return; // stop the pass; reconnect restarts it
      } catch (e) {
        // Unknown errors are treated as transient but still counted.
        await outbox.retryLater(
          op,
          backoff(op.attempts, rng: _rng),
          e.toString(),
        );
      }
    }
  }

  Future<void> _fail(OutboxOp op, String error) async {
    await outbox.fail(op, error);
    onPermanentFailure?.call(op, error);
  }

  void _scheduleNext() {
    _timer?.cancel();
    final pending = outbox.all().where(
      (o) => o.state == OpState.pending && o.nextAt != null,
    );
    if (pending.isEmpty) return;
    final soonest = pending
        .map((o) => o.nextAt!)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final wait = soonest.difference(DateTime.now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, drain);
  }

  void dispose() => _timer?.cancel();
}
