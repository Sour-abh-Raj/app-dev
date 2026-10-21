import 'dart:convert';
import 'dart:io';

import '../../core/errors.dart';
import '../../domain/models.dart';
import '../api/ai_api.dart';
import '../local/local_store.dart';
import '../remote/remote.dart';
import 'outbox.dart';
import 'sync_engine.dart';

/// Op kinds understood by the sync engine.
class Ops {
  const Ops._();
  static const upsert = 'doc.upsert';
  static const upload = 'storage.upload';
  static const aiMeal = 'ai.meal';
  static const aiCheckin = 'ai.checkin';
  static const aiReplan = 'ai.replan';
}

/// Outbox handlers. Each is idempotent: replays overwrite the same document,
/// re-upload to the same path, or reuse the same AI idempotency key.
class SyncHandlers {
  SyncHandlers({
    required this.local,
    required this.remote,
    required this.api,
    required this.uid,
    this.onCapReached,
    this.onCheckinReport,
  });

  final LocalStore local;
  final Remote remote;
  final AiApi api;
  final String? Function() uid;
  final void Function(CapReachedError e)? onCapReached;
  final void Function(Checkin c)? onCheckinReport;

  String _uid() {
    final u = uid();
    if (u == null) throw const TransientError('signed out');
    return u;
  }

  Map<String, OpHandler> get map => {
    Ops.upsert: _upsert,
    Ops.upload: _upload,
    Ops.aiMeal: _aiMeal,
    Ops.aiCheckin: _aiCheckin,
    Ops.aiReplan: _aiReplan,
  };

  Future<void> _upsert(OutboxOp op) => remote.upsert(
    _uid(),
    op.payload['collection'] as String,
    op.payload['id'] as String,
    Map<String, dynamic>.from(op.payload['data'] as Map),
  );

  Future<void> _upload(OutboxOp op) => remote.upload(
    op.payload['local_path'] as String,
    op.payload['storage_path'] as String,
  );

  Future<void> _aiMeal(OutboxOp op) async {
    final id = op.payload['meal_id'] as String;
    final meal = local.meal(id);
    if (meal == null) return; // deleted locally — nothing to analyse
    String? b64;
    if (meal.localPhoto != null && await File(meal.localPhoto!).exists()) {
      b64 = base64Encode(await File(meal.localPhoto!).readAsBytes());
    }
    try {
      final macros = await api.analyzeMeal(
        photoB64: b64,
        text: meal.text,
        idemKey: op.payload['idem_key'] as String,
      );
      final updated = meal.copyWith(ai: macros, status: MealStatus.done);
      await local.saveMeal(updated);
      await remote.upsert(_uid(), 'meals', id, mealDoc(updated));
    } on CapReachedError catch (e) {
      await local.saveMeal(meal.copyWith(status: MealStatus.capReached));
      onCapReached?.call(e);
      // The meal stays logged (manual macros); the AI job is dropped, not retried.
    } on PermanentError {
      await local.saveMeal(meal.copyWith(status: MealStatus.failed));
      rethrow;
    }
  }

  Future<void> _aiCheckin(OutboxOp op) async {
    final id = op.payload['checkin_id'] as String;
    final c = local.checkin(id);
    if (c == null) return;
    if (c.photos.any((p) => p.path == null)) {
      throw const TransientError(
        'photos still uploading',
        retryAfter: Duration(seconds: 5),
      );
    }
    final history = local.checkins
        .where((h) => h.id != id && h.weekIndex < c.weekIndex)
        .toList();
    final body = {
      'checkin_id': id,
      'week_index': c.weekIndex,
      'weight_kg': c.weightKg,
      'photos': [
        for (final p in c.photos) {'angle': p.angle, 'path': p.path},
      ],
      'survey': c.survey.toJson(),
      'history': [
        for (final h in history.take(12))
          {
            'week_index': h.weekIndex,
            'weight_kg': h.weightKg,
            'photos': [
              for (final p in h.photos.where((p) => p.path != null))
                {'angle': p.angle, 'path': p.path},
            ],
          },
      ],
    };
    await local.saveCheckin(c.copyWith(status: CheckinStatus.analyzing));
    try {
      final res = await api.analyzeCheckin(body, idemKey: 'checkin-$id');
      if (res.queued || res.report == null) {
        await local.saveCheckin(c.copyWith(status: CheckinStatus.queued));
        throw const TransientError(
          'analysis queued',
          retryAfter: Duration(minutes: 2),
        );
      }
      final done = c.copyWith(report: res.report, status: CheckinStatus.done);
      await local.saveCheckin(done);
      onCheckinReport?.call(done);
    } on CapReachedError catch (e) {
      await local.saveCheckin(c.copyWith(status: CheckinStatus.manual));
      onCapReached?.call(e);
    }
  }

  Future<void> _aiReplan(OutboxOp op) async {
    final plan = local.plan;
    if (plan == null) return;
    try {
      final res = await api.regeneratePlan(
        uid: _uid(),
        week: op.payload['week'] as int,
        planned: op.payload['planned'] as int,
        completed: op.payload['completed'] as int,
        survey: op.payload['survey'] == null
            ? null
            : Survey.fromJson(op.payload['survey'] as Map),
        current: plan.mesocycle,
        idemKey: op.payload['idem_key'] as String,
      );
      // The new mesocycle starts at the week being planned; absolute week
      // numbers (workouts, check-ins) keep counting from the programme start.
      final week = op.payload['week'] as int;
      await local.savePlan(
        Plan(
          version: res.version,
          startDate: plan.startDate,
          weekOffset: week - 1,
          mesocycle: res.mesocycle,
          source: res.source,
          queued: res.queued,
          cycle: plan.cycle + 1,
        ),
      );
    } on CapReachedError {
      // Free/grace: keep the static plan (free forever includes the starter plan).
    }
  }

  static Map<String, dynamic> mealDoc(Meal m) => {
    'photo_path': m.photoPath,
    'text': m.text,
    'ai': m.ai?.toJson(),
    'override': m.override?.toJson(),
    'logged_at': m.loggedAt.toUtc().toIso8601String(),
  };
}
