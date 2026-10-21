import 'package:flutter_test/flutter_test.dart';
import 'package:forme/core/clock.dart';
import 'package:forme/domain/models.dart';
import 'package:forme/domain/training.dart';

import '../helpers.dart';

Workout done(
  Plan p,
  int week,
  int day, {
  List<SetLog> sets = const [],
  bool catchup = false,
  DateTime? at,
}) => Workout(
  id: '${workoutId(p.version, week, day)}${catchup ? 'c' : ''}',
  planVersion: p.version,
  week: week,
  dayIndex: day,
  sessionName: 'S',
  scheduledFor: dateOf(p, week, day),
  finishedAt: at ?? dateOf(p, week, day).add(const Duration(hours: 18)),
  sets: sets,
  catchup: catchup,
);

void main() {
  final lib = loadLib();
  final start = DateTime(2026, 10, 19); // a Monday
  final p = plan(start); // 3 days: offsets 0, 2, 4

  group('position', () {
    test('week/day from start date, wrapping the 4-week mesocycle', () {
      expect(positionOf(p, start).week, 1);
      expect(positionOf(p, start).dayNumber, 1);
      final d10 = positionOf(p, start.add(const Duration(days: 10)));
      expect((d10.week, d10.dayOffset), (2, 3));
      expect(
        positionOf(p, start.add(const Duration(days: 35))).mesoWeek,
        2,
      ); // week 6 → meso 2
      expect(positionOf(p, start.subtract(const Duration(days: 3))).week, 1);
    });

    test('a re-plan offset restarts the mesocycle', () {
      final replanned = Plan(
        version: 2,
        startDate: start,
        mesocycle: p.mesocycle,
        source: 'ai',
        weekOffset: 4,
      );
      expect(
        positionOf(replanned, start.add(const Duration(days: 28))).mesoWeek,
        1,
      );
      expect(mesoWeekOf(replanned, 7), 3);
    });

    test('sessionOn returns sessions only on training days', () {
      expect(sessionOn(p, start), isNotNull);
      expect(sessionOn(p, start.add(const Duration(days: 1))), isNull);
      expect(sessionOn(p, start.add(const Duration(days: 2))), isNotNull);
    });

    test('daysBetween is DST-safe', () {
      expect(daysBetween(DateTime(2026, 3, 28), DateTime(2026, 3, 30)), 2);
      expect(
        daysBetween(DateTime(2026, 10, 24, 23), DateTime(2026, 10, 26, 1)),
        2,
      );
    });
  });

  group('catch-up and streak', () {
    test('missed session earlier in the week is offered as a catch-up', () {
      final wed = start.add(const Duration(days: 3));
      final missed = missedThisWeek(p, const [], wed);
      expect(missed?.dayIndex, 2); // most recent miss
      final c = catchupOf(missed!);
      expect(c.estMins, 20);
      expect(c.exercises.length, lessThanOrEqualTo(3));
      expect(c.exercises.every((e) => e.sets <= 2), isTrue);
      expect(missedThisWeek(p, [done(p, 1, 0), done(p, 1, 2)], wed), isNull);
    });

    test('streak counts sessions and resets on an un-caught-up miss', () {
      final day9 = start.add(const Duration(days: 9)); // week 2, offset 2
      expect(
        streak(p, [
          done(p, 1, 0),
          done(p, 1, 2),
          done(p, 1, 4),
          done(p, 2, 0),
        ], day9),
        4,
      );
      // Missed week-1 day 4 resets: only week-2 day 0 counts.
      expect(streak(p, [done(p, 1, 0), done(p, 1, 2), done(p, 2, 0)], day9), 1);
      // A catch-up for that day counts as done.
      expect(
        streak(p, [
          done(p, 1, 0),
          done(p, 1, 2),
          done(p, 1, 4, catchup: true),
          done(p, 2, 0),
        ], day9),
        4,
      );
    });

    test('adherence snapshot', () {
      final a = adherence(p, [done(p, 1, 0), done(p, 1, 4)], 1);
      expect((a.planned, a.completed), (3, 2));
    });
  });

  group('sets, volume, PRs', () {
    SetLog s(String ex, int n, int reps, double kg, {bool doneSet = true}) =>
        SetLog(exId: ex, setN: n, reps: reps, loadKg: kg, done: doneSet);

    test('volume counts only done sets', () {
      expect(
        volumeOf([s('a', 1, 10, 10), s('a', 2, 10, 10, doneSet: false)]),
        100,
      );
    });

    test('e1rm (Epley)', () => expect(e1rm(100, 10), closeTo(133.33, 0.01)));

    test('PRs: loaded by e1RM, bodyweight by reps, first time is not a PR', () {
      final old = done(
        p,
        1,
        0,
        sets: [s('goblet_squat', 1, 10, 12), s('pushup', 1, 10, 0)],
      );
      final now = Workout(
        id: 'now',
        planVersion: 1,
        week: 1,
        dayIndex: 2,
        sessionName: 'S',
        scheduledFor: start,
        finishedAt: start,
        sets: [
          s('goblet_squat', 1, 10, 14),
          s('pushup', 1, 12, 0),
          s('plank', 1, 30, 0),
        ],
      );
      expect(detectPrs(now, [old]), ['goblet_squat', 'pushup']);
    });

    test('prefill: +2.5 kg after hitting every target, else repeat', () {
      const target = SessionExercise(
        exId: 'goblet_squat',
        sets: 2,
        reps: '10-15',
        restS: 60,
      );
      final hit = done(
        p,
        1,
        0,
        sets: [s('goblet_squat', 1, 10, 12), s('goblet_squat', 2, 10, 12)],
      );
      expect(prefillLoad('goblet_squat', target, [hit], lib), 14.5);
      final miss = done(
        p,
        1,
        0,
        sets: [s('goblet_squat', 1, 10, 12), s('goblet_squat', 2, 8, 12)],
      );
      expect(prefillLoad('goblet_squat', target, [miss], lib), 12);
      expect(prefillLoad('goblet_squat', target, const [], lib), 0);
      expect(prefillLoad('pushup', target, [hit], lib), 0); // bodyweight
    });

    test('startWorkout prefills every set', () {
      final session = sessionOn(p, start)!;
      final w = startWorkout(
        plan: p,
        session: session,
        week: 1,
        now: start,
        history: const [],
        lib: lib,
      );
      expect(
        w.sets.length,
        session.exercises.fold<int>(0, (a, e) => a + e.sets),
      );
      expect(w.sets.every((x) => !x.done && x.reps > 0), isTrue);
      expect(w.id, 'p1w1d0');
      final c = startWorkout(
        plan: p,
        session: session,
        week: 1,
        now: start,
        history: const [],
        lib: lib,
        catchup: true,
      );
      expect(c.id, 'p1w1d0c');
    });

    test('target reps parsing', () {
      expect(
        const SessionExercise(
          exId: 'x',
          sets: 1,
          reps: '8-12',
          restS: 1,
        ).targetReps,
        8,
      );
      expect(
        const SessionExercise(
          exId: 'x',
          sets: 1,
          reps: '30s',
          restS: 1,
        ).targetReps,
        30,
      );
      expect(
        const SessionExercise(exId: 'x', sets: 1, reps: '30s', restS: 1).timed,
        isTrue,
      );
      expect(
        const SessionExercise(
          exId: 'x',
          sets: 1,
          reps: 'max',
          restS: 1,
        ).targetReps,
        10,
      );
    });
  });
}
