import 'dart:async';
import 'dart:math' as math;

import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

enum OpState { pending, failed }

/// One durable mutation waiting to reach the server.
class OutboxOp {
  const OutboxOp({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
    this.nextAt,
    this.state = OpState.pending,
    this.error,
    this.seq = 0,
  });

  final String id;
  final String kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int attempts;
  final DateTime? nextAt;
  final OpState state;
  final String? error;
  final int seq;

  bool dueAt(DateTime now) =>
      state == OpState.pending && (nextAt == null || !nextAt!.isAfter(now));

  OutboxOp copyWith({
    int? attempts,
    DateTime? nextAt,
    OpState? state,
    String? error,
  }) => OutboxOp(
    id: id,
    kind: kind,
    payload: payload,
    createdAt: createdAt,
    attempts: attempts ?? this.attempts,
    nextAt: nextAt ?? this.nextAt,
    state: state ?? this.state,
    error: error ?? this.error,
    seq: seq,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'payload': payload,
    'created_at': createdAt.toIso8601String(),
    'attempts': attempts,
    'next_at': nextAt?.toIso8601String(),
    'state': state.name,
    'error': error,
    'seq': seq,
  };

  factory OutboxOp.fromJson(Map<dynamic, dynamic> j) => OutboxOp(
    id: j['id'] as String,
    kind: j['kind'] as String,
    payload: Map<String, dynamic>.from(_deep(j['payload']) as Map),
    createdAt: DateTime.parse(j['created_at'] as String),
    attempts: j['attempts'] as int? ?? 0,
    nextAt: j['next_at'] == null
        ? null
        : DateTime.parse(j['next_at'] as String),
    state: OpState.values.firstWhere(
      (s) => s.name == j['state'],
      orElse: () => OpState.pending,
    ),
    error: j['error'] as String?,
    seq: j['seq'] as int? ?? 0,
  );
}

/// Hive returns `Map<dynamic, dynamic>`; normalise nested maps to String keys.
Object? _deep(Object? v) {
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), _deep(val)));
  if (v is List) return v.map(_deep).toList();
  return v;
}

/// Exponential backoff with full jitter: random(0, min(cap, base·2^n)).
Duration backoff(
  int attempts, {
  math.Random? rng,
  Duration base = const Duration(seconds: 2),
  Duration cap = const Duration(minutes: 10),
}) {
  final r = rng ?? math.Random();
  final exp = base.inMilliseconds * math.pow(2, math.min(attempts, 20));
  final ceiling = math.min(cap.inMilliseconds.toDouble(), exp.toDouble());
  return Duration(
    milliseconds: (r.nextDouble() * ceiling).round().clamp(
      250,
      cap.inMilliseconds,
    ),
  );
}

/// Persistent FIFO queue (O1). `enqueue` resolves only after the op is
/// flushed to disk, so callers ack the UI after the write is durable.
class Outbox {
  Outbox(this._box, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Box<dynamic> _box;
  final DateTime Function() _now;
  final _uuid = const Uuid();
  final _changed = StreamController<void>.broadcast();

  Stream<void> get changed => _changed.stream;

  int _nextSeq() {
    var max = 0;
    for (final v in _box.values) {
      final s = (v as Map)['seq'] as int? ?? 0;
      if (s > max) max = s;
    }
    return max + 1;
  }

  /// [dedupeKey] replaces an older pending op with the same key (e.g. repeated
  /// upserts of one workout collapse into the latest state).
  Future<OutboxOp> enqueue(
    String kind,
    Map<String, dynamic> payload, {
    String? dedupeKey,
  }) async {
    if (dedupeKey != null) {
      for (final op in all()) {
        if (op.payload['_dedupe'] == dedupeKey && op.state == OpState.pending) {
          await _box.delete(op.id);
        }
      }
    }
    final op = OutboxOp(
      id: _uuid.v4(),
      kind: kind,
      payload: {...payload, '_dedupe': ?dedupeKey},
      createdAt: _now(),
      seq: _nextSeq(),
    );
    await _box.put(op.id, op.toJson());
    await _box.flush();
    _changed.add(null);
    return op;
  }

  List<OutboxOp> all() =>
      _box.values.map((j) => OutboxOp.fromJson(j as Map)).toList()
        ..sort((a, b) => a.seq.compareTo(b.seq));

  List<OutboxOp> due() => all().where((o) => o.dueAt(_now())).toList();

  List<OutboxOp> failed() =>
      all().where((o) => o.state == OpState.failed).toList();

  int get pendingCount => all().where((o) => o.state == OpState.pending).length;

  Future<void> complete(OutboxOp op) async {
    await _box.delete(op.id);
    await _box.flush();
    _changed.add(null);
  }

  Future<void> retryLater(OutboxOp op, Duration wait, String error) async {
    await _box.put(
      op.id,
      op
          .copyWith(
            attempts: op.attempts + 1,
            nextAt: _now().add(wait),
            error: error,
          )
          .toJson(),
    );
    await _box.flush();
    _changed.add(null);
  }

  Future<void> fail(OutboxOp op, String error) async {
    await _box.put(
      op.id,
      op.copyWith(state: OpState.failed, error: error).toJson(),
    );
    await _box.flush();
    _changed.add(null);
  }

  /// User-initiated retry of permanently failed ops.
  Future<void> requeueFailed() async {
    for (final op in failed()) {
      await _box.put(
        op.id,
        op
            .copyWith(state: OpState.pending, attempts: 0, nextAt: _now())
            .toJson(),
      );
    }
    await _box.flush();
    _changed.add(null);
  }

  Future<void> discard(OutboxOp op) => complete(op);
}
