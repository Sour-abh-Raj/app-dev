import 'dart:math' as math;

import '../core/clock.dart';
import 'exercise_library.dart';
import 'models.dart';

/// Where today sits in the plan. Weeks are counted from the plan's start date
/// (Week 1 Day 1); the 4-week mesocycle repeats until a re-plan replaces it.
class PlanPosition {
  const PlanPosition({
    required this.week,
    required this.mesoWeek,
    required this.dayOffset,
  });

  final int week; // absolute, 1-based
  final int mesoWeek; // 1..mesocycle length
  final int dayOffset; // 0..6 within the week

  int get dayNumber => dayOffset + 1;
}

PlanPosition positionOf(Plan plan, DateTime date) {
  final d = math.max(0, daysBetween(plan.startDate, date));
  final week = d ~/ 7 + 1;
  return PlanPosition(
    week: week,
    mesoWeek: mesoWeekOf(plan, week),
    dayOffset: d % 7,
  );
}

int mesoWeekOf(Plan plan, int week) {
  final len = plan.mesocycle.weeks.length;
  return math.max(0, week - 1 - plan.weekOffset) % len + 1;
}

PlanWeek weekOf(Plan plan, int mesoWeek) => plan.mesocycle.weeks.firstWhere(
  (w) => w.weekIndex == mesoWeek,
  orElse: () => plan.mesocycle.weeks.first,
);

PlanSession? sessionOn(Plan plan, DateTime date) {
  final pos = positionOf(plan, date);
  for (final s in weekOf(plan, pos.mesoWeek).sessions) {
    if (s.dayIndex == pos.dayOffset) return s;
  }
  return null;
}

DateTime dateOf(Plan plan, int week, int dayIndex) =>
    dateOnly(plan.startDate).add(Duration(days: (week - 1) * 7 + dayIndex));

String workoutId(int planVersion, int week, int dayIndex) =>
    'p${planVersion}w${week}d$dayIndex';

bool _done(List<Workout> ws, int week, int day) =>
    ws.any((w) => w.week == week && w.dayIndex == day && w.finished);

/// Sessions earlier this week that were not done — offered as a "20-min
/// catch-up?" (never shaming copy). Only the most recent one is offered.
PlanSession? missedThisWeek(Plan plan, List<Workout> workouts, DateTime today) {
  final pos = positionOf(plan, today);
  PlanSession? missed;
  for (final s in weekOf(plan, pos.mesoWeek).sessions) {
    if (s.dayIndex < pos.dayOffset && !_done(workouts, pos.week, s.dayIndex)) {
      missed = s;
    }
  }
  return missed;
}

/// A shorter version of a missed session: top 3 exercises, max 2 sets each.
PlanSession catchupOf(PlanSession s) => PlanSession(
  dayIndex: s.dayIndex,
  name: '${s.name} · catch-up',
  estMins: 20,
  exercises: [
    for (final e in s.exercises.take(3)) e.copyWith(sets: math.min(2, e.sets)),
  ],
);

/// Completed sessions since the last un-caught-up miss.
int streak(Plan plan, List<Workout> workouts, DateTime today) {
  final pos = positionOf(plan, today);
  var count = 0;
  for (var w = 1; w <= pos.week; w++) {
    for (final s in weekOf(plan, mesoWeekOf(plan, w)).sessions) {
      final isPast = w < pos.week || s.dayIndex < pos.dayOffset;
      final isToday = w == pos.week && s.dayIndex == pos.dayOffset;
      if (_done(workouts, w, s.dayIndex)) {
        count++;
      } else if (isPast) {
        count = 0; // a catch-up for the same day counts as done above
      } else if (!isPast && !isToday) {
        break;
      }
    }
  }
  return count;
}

// ---------- set logging ----------

double volumeOf(Iterable<SetLog> sets) =>
    sets.where((s) => s.done).fold(0.0, (v, s) => v + s.loadKg * s.reps);

/// Epley estimated 1RM.
double e1rm(double load, int reps) => load * (1 + reps / 30);

/// Exercises in [current] that beat every earlier finished workout.
/// Loaded lifts compare e1RM; bodyweight/timed work compares reps.
List<String> detectPrs(Workout current, List<Workout> history) {
  final best = <String, double>{};
  for (final w in history) {
    if (!w.finished || w.id == current.id) continue;
    for (final s in w.sets.where((s) => s.done)) {
      final score = s.loadKg > 0 ? e1rm(s.loadKg, s.reps) : s.reps.toDouble();
      best[s.exId] = math.max(best[s.exId] ?? 0, score);
    }
  }
  final prs = <String>{};
  for (final s in current.sets.where((s) => s.done)) {
    final score = s.loadKg > 0 ? e1rm(s.loadKg, s.reps) : s.reps.toDouble();
    final prev = best[s.exId];
    if (prev != null && score > prev + 1e-9) prs.add(s.exId);
  }
  return prs.toList()..sort();
}

/// Load to prefill for the next set of [exId]: last logged load, +2.5 kg when
/// every set last time hit the target reps (simple double progression).
double prefillLoad(
  String exId,
  SessionExercise target,
  List<Workout> history,
  ExerciseLibrary lib,
) {
  final ex = lib[exId];
  if (ex == null || !ex.loadable) return 0;
  final sorted = [...history.where((w) => w.finished)]
    ..sort((a, b) => b.finishedAt!.compareTo(a.finishedAt!));
  for (final w in sorted) {
    final sets = w.sets.where((s) => s.exId == exId && s.done).toList();
    if (sets.isEmpty) continue;
    final last = sets.map((s) => s.loadKg).reduce(math.max);
    final hitAll =
        sets.length >= target.sets &&
        sets.every((s) => s.reps >= target.targetReps);
    return hitAll ? last + 2.5 : last;
  }
  return target.loadKg ?? 0;
}

/// Fresh workout for a session, with every set prefilled (sets×reps×load).
Workout startWorkout({
  required Plan plan,
  required PlanSession session,
  required int week,
  required DateTime now,
  required List<Workout> history,
  required ExerciseLibrary lib,
  bool catchup = false,
}) {
  final sets = <SetLog>[];
  for (final e in session.exercises) {
    final load = prefillLoad(e.exId, e, history, lib);
    for (var n = 1; n <= e.sets; n++) {
      sets.add(
        SetLog(
          exId: e.exId,
          setN: n,
          reps: e.targetReps,
          loadKg: load,
          done: false,
        ),
      );
    }
  }
  return Workout(
    id: workoutId(plan.version, week, session.dayIndex) + (catchup ? 'c' : ''),
    planVersion: plan.version,
    week: week,
    dayIndex: session.dayIndex,
    sessionName: session.name,
    scheduledFor: dateOf(plan, week, session.dayIndex),
    startedAt: now,
    sets: sets,
    catchup: catchup,
    updatedAt: now,
  );
}

/// Adherence snapshot sent to /v1/plan/regenerate.
({int planned, int completed}) adherence(
  Plan plan,
  List<Workout> ws,
  int week,
) {
  final sessions = weekOf(plan, mesoWeekOf(plan, week)).sessions;
  final done = sessions.where((s) => _done(ws, week, s.dayIndex)).length;
  return (planned: sessions.length, completed: done);
}
