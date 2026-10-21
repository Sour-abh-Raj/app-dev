import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/errors.dart';
import '../domain/exercise_library.dart';
import '../domain/models.dart';
import '../domain/plan_engine.dart';
import '../domain/training.dart';
import '../services/analytics.dart';
import 'api/ai_api.dart';
import 'local/local_store.dart';
import 'sync/handlers.dart';
import 'sync/outbox.dart';
import 'sync/sync_engine.dart';

/// Every user mutation goes through here: write Hive → enqueue outbox op →
/// (only then) return to the UI → kick the sync engine (O1).
class Repo {
  Repo({
    required this.local,
    required this.outbox,
    required this.sync,
    required this.api,
    required this.lib,
    required this.analytics,
    required this.uid,
    required this.now,
  });

  final LocalStore local;
  final Outbox outbox;
  final SyncEngine sync;
  final AiApi api;
  final ExerciseLibrary lib;
  final Analytics analytics;
  final String? Function() uid;
  final DateTime Function() now;
  static const _uuid = Uuid();

  void _kick() => unawaited(sync.drain());

  Future<void> _upsert(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) => outbox.enqueue(Ops.upsert, {
    'collection': collection,
    'id': id,
    'data': data,
  }, dedupeKey: '$collection/$id');

  // ---------- profile & plan ----------

  Future<void> saveProfile(Profile p) async {
    await local.saveProfile(p);
    await _upsert('', 'me', p.toFirestore());
    _kick();
  }

  /// Plan for a new user: AI first, template fallback ("template applied").
  Future<Plan> createPlan(Profile p) async {
    final start = now();
    Plan plan;
    try {
      final r = await api.generatePlan(
        p,
        idemKey: 'plan-gen-${uid() ?? 'anon'}',
      );
      plan = Plan(
        version: r.version,
        startDate: start,
        mesocycle: r.mesocycle,
        source: r.source,
        queued: r.queued,
      );
    } on AppError {
      plan = Plan(
        version: 1,
        startDate: start,
        mesocycle: PlanEngine(lib).template(p),
        source: 'template',
        queued: true,
      );
      await _upsert('plans', 'v1', {
        'version': 1,
        'week_index': 1,
        'mesocycle_json': plan.mesocycle.toJson(),
        'source': 'template',
      });
    }
    await local.savePlan(plan);
    _kick();
    return plan;
  }

  /// Weekly adaptive re-plan (Pro). Queued; free users keep the static plan.
  Future<void> requestReplan({required int week, Survey? survey}) async {
    final plan = local.plan;
    if (plan == null) return;
    final a = adherence(plan, local.workouts, week - 1 < 1 ? 1 : week - 1);
    await outbox.enqueue(Ops.aiReplan, {
      'week': week,
      'planned': a.planned,
      'completed': a.completed,
      'survey': survey?.toJson(),
      'idem_key': 'replan-${plan.version}-$week',
    }, dedupeKey: 'replan-$week');
    _kick();
  }

  // ---------- workouts ----------

  Future<void> saveWorkout(Workout w) async {
    final stamped = w.copyWith(updatedAt: now());
    await local.saveWorkout(stamped);
    await _upsert('workouts', w.id, stamped.toJson());
    _kick();
  }

  Future<Workout> finishWorkout(Workout w) async {
    final t = now();
    final done = w.copyWith(
      finishedAt: t,
      volumeKg: volumeOf(w.sets),
      prs: detectPrs(w, local.workouts),
      updatedAt: t,
    );
    await saveWorkout(done);
    await analytics.log(Events.workoutFinished, {
      'volume_kg': done.volumeKg.round(),
      'prs': done.prs.length,
      'catchup': done.catchup ? 1 : 0,
    });
    return done;
  }

  // ---------- meals ----------

  /// Logs a meal immediately (offline-safe) and queues AI analysis when
  /// [analyze] is set. Returns the stored meal.
  Future<Meal> logMeal({
    String? localPhoto,
    String? text,
    Macros? manual,
    bool analyze = true,
  }) async {
    final id = _uuid.v4();
    final meal = Meal(
      id: id,
      loggedAt: now(),
      localPhoto: localPhoto,
      photoPath: localPhoto == null ? null : 'meals/${uid()}/$id.jpg',
      text: text,
      override: manual,
      status: analyze ? MealStatus.analyzing : MealStatus.done,
      idemKey: 'meal-$id',
    );
    await local.saveMeal(meal);
    if (localPhoto != null) {
      await outbox.enqueue(Ops.upload, {
        'local_path': localPhoto,
        'storage_path': meal.photoPath,
      });
    }
    await _upsert('meals', id, SyncHandlers.mealDoc(meal));
    if (analyze) {
      await outbox.enqueue(Ops.aiMeal, {
        'meal_id': id,
        'idem_key': meal.idemKey,
      });
    }
    await analytics.log(Events.mealLogged, {
      'ai': analyze ? 1 : 0,
      'photo': localPhoto != null ? 1 : 0,
    });
    _kick();
    return meal;
  }

  /// Fast path for the meal screen: try the AI right away (≤15 s budget).
  /// On offline/timeout the queued op finishes the job later.
  Future<Meal> analyzeNow(Meal meal) async {
    await sync.drain();
    return local.meal(meal.id) ?? meal;
  }

  Future<void> updateMeal(Meal m) async {
    await local.saveMeal(m);
    await _upsert('meals', m.id, SyncHandlers.mealDoc(m));
    _kick();
  }

  Future<void> deleteMeal(String id) async {
    await local.deleteMeal(id);
    _kick();
  }

  // ---------- check-ins ----------

  Future<void> saveCheckinDraft(Checkin c) => local.saveCheckin(c);

  /// Submit: upload photos (resumable via retry), save the doc, queue the AI
  /// report (Pro) — or keep it as a manual side-by-side (free/grace).
  Future<Checkin> submitCheckin(Checkin c, {required bool aiReport}) async {
    final u = uid();
    final photos = [
      for (final p in c.photos)
        p.copyWith(path: 'progress-photos/$u/${c.id}/${p.angle}.jpg'),
    ];
    final submitted = c.copyWith(
      photos: photos,
      status: aiReport ? CheckinStatus.uploading : CheckinStatus.manual,
    );
    await local.saveCheckin(submitted);
    for (final p in photos) {
      await outbox.enqueue(Ops.upload, {
        'local_path': p.localPath,
        'storage_path': p.path,
      }, dedupeKey: 'upload/${p.path}');
    }
    await _upsert('checkins', c.id, {
      'id': c.id,
      'week_index': c.weekIndex,
      'weight_kg': c.weightKg,
      'photos': [
        for (final p in photos)
          {'angle': p.angle, 'path': p.path, 'thumb': p.thumb},
      ],
      'survey': c.survey.toJson(),
      'created_at': c.createdAt.toUtc().toIso8601String(),
    });
    if (aiReport) {
      await outbox.enqueue(Ops.aiCheckin, {
        'checkin_id': c.id,
      }, dedupeKey: 'ai/${c.id}');
    }
    await analytics.log(Events.checkinSubmitted, {
      'ai': aiReport ? 1 : 0,
      'week': c.weekIndex,
    });
    _kick();
    return submitted;
  }

  Future<void> retryFailed() async {
    await outbox.requeueFailed();
    _kick();
  }

  // ---------- coach ----------

  Future<CoachReply> chat(String text, Map<String, dynamic> capsule) async {
    final user = ChatMessage(role: 'user', content: text.trim(), ts: now());
    await local.addChat(user);
    final reply = await api.chat(
      local.chat,
      capsule,
      idemKey: 'chat-${user.ts.microsecondsSinceEpoch}',
    );
    await local.addChat(
      ChatMessage(
        role: 'assistant',
        content: reply.reply,
        ts: now(),
        flagged: reply.flagged,
      ),
    );
    return reply;
  }
}
