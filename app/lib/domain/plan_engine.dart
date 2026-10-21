import 'dart:math' as math;

import 'exercise_library.dart';
import 'models.dart';

/// Deterministic template planner — the offline fallback when the AI plan is
/// unavailable ("analysis queued — template applied"). Mirrors
/// ai_service/app/plan_engine.py; keep the two in step.
class PlanEngine {
  PlanEngine(this.library);

  final ExerciseLibrary library;

  static const _levelMax = {
    Level.beginner: 1,
    Level.intermediate: 2,
    Level.advanced: 3,
  };

  static const templates = <String, List<String>>{
    'full_a': [
      'quads',
      'chest',
      'back',
      'hamstrings',
      'shoulders',
      'core',
      'biceps',
    ],
    'full_b': [
      'hamstrings',
      'back',
      'chest',
      'quads',
      'rear_delts',
      'core',
      'triceps',
    ],
    'upper': [
      'chest',
      'back',
      'shoulders',
      'back',
      'triceps',
      'biceps',
      'rear_delts',
    ],
    'lower': [
      'quads',
      'hamstrings',
      'glutes',
      'quads',
      'calves',
      'core',
      'hamstrings',
    ],
    'push': [
      'chest',
      'shoulders',
      'chest',
      'triceps',
      'shoulders',
      'core',
      'triceps',
    ],
    'pull': ['back', 'back', 'rear_delts', 'biceps', 'back', 'core', 'biceps'],
    'legs': [
      'quads',
      'hamstrings',
      'glutes',
      'quads',
      'calves',
      'core',
      'hamstrings',
    ],
  };
  static const splits = <int, List<String>>{
    2: ['full_a', 'full_b'],
    3: ['full_a', 'full_b', 'full_a'],
    4: ['upper', 'lower', 'upper', 'lower'],
    5: ['push', 'pull', 'legs', 'upper', 'lower'],
    6: ['push', 'pull', 'legs', 'push', 'pull', 'legs'],
  };
  static const days = <int, List<int>>{
    2: [0, 3],
    3: [0, 2, 4],
    4: [0, 1, 3, 4],
    5: [0, 1, 2, 4, 5],
    6: [0, 1, 2, 3, 4, 5],
  };
  static const names = {
    'full_a': 'Full-body A',
    'full_b': 'Full-body B',
    'upper': 'Upper',
    'lower': 'Lower',
    'push': 'Push',
    'pull': 'Pull',
    'legs': 'Legs',
  };
  static const _dose = <Goal, (int, String, int)>{
    Goal.strength: (4, '5', 150),
    Goal.buildMuscle: (3, '8-12', 90),
    Goal.recomp: (3, '8-10', 75),
    Goal.loseFat: (3, '10-15', 60),
  };

  static int slotsForMinutes(int mins) {
    if (mins < 30) return 4;
    if (mins < 45) return 5;
    if (mins <= 60) return 6;
    return 7;
  }

  Exercise? _pick(
    String muscle,
    Set<String> used,
    Set<String> eq,
    Set<String> inj,
    int maxD,
  ) {
    final c =
        library.all
            .where(
              (e) =>
                  e.muscle == muscle &&
                  !used.contains(e.id) &&
                  library.allowed(e, eq, inj, maxD),
            )
            .toList()
          ..sort((a, b) {
            final d = b.difficulty.compareTo(a.difficulty);
            if (d != 0) return d;
            final l = b.needs.length.compareTo(a.needs.length);
            if (l != 0) return l;
            return a.id.compareTo(b.id);
          });
    return c.isEmpty ? null : c.first;
  }

  Mesocycle template(Profile p) {
    final eq = p.equipment.toSet()..remove('bodyweight');
    final inj = p.injuries.toSet();
    final maxD = _levelMax[p.level]!;
    final (sets, reps, rest) = _dose[p.goal]!;
    final nSlots = slotsForMinutes(p.mins);
    final dpw = p.daysPerWeek.clamp(2, 6);

    final base = <PlanSession>[];
    final split = splits[dpw]!;
    for (var i = 0; i < split.length; i++) {
      final tmpl = split[i];
      final used = <String>{};
      final exs = <SessionExercise>[];
      for (final muscle in [...templates[tmpl]!, ...templates[tmpl]!]) {
        if (exs.length >= nSlots) break;
        final ex = _pick(muscle, used, eq, inj, maxD);
        if (ex == null) continue;
        used.add(ex.id);
        exs.add(
          SessionExercise(
            exId: ex.id,
            sets: ex.timed ? 3 : sets,
            reps: ex.timed ? '30s' : reps,
            restS: ex.timed ? 60 : rest,
          ),
        );
      }
      if (exs.isEmpty) {
        exs.addAll(const [
          SessionExercise(exId: 'dead_bug', sets: 3, reps: '10', restS: 45),
          SessionExercise(exId: 'glute_bridge', sets: 3, reps: '12', restS: 45),
        ]);
      }
      base.add(
        PlanSession(
          dayIndex: days[dpw]![i],
          name: names[tmpl]!,
          estMins: p.mins,
          exercises: exs,
        ),
      );
    }

    final weeks = <PlanWeek>[];
    for (var w = 1; w <= 4; w++) {
      weeks.add(
        PlanWeek(
          weekIndex: w,
          sessions: [
            for (final s in base)
              PlanSession(
                dayIndex: s.dayIndex,
                name: s.name,
                estMins: s.estMins,
                exercises: [
                  for (var i = 0; i < s.exercises.length; i++)
                    s.exercises[i].copyWith(
                      sets: math.max(1, s.exercises[i].sets + _delta(w, i)),
                    ),
                ],
              ),
          ],
        ),
      );
    }
    final (kcal, protein) = nutritionTargets(p);
    return Mesocycle(
      name: '${names[split.first]} · ${dpw}x/week',
      weeks: weeks,
      kcalTarget: kcal,
      proteinG: protein,
      notes: 'Starter template. Week 4 is a deload.',
    );
  }

  static int _delta(int week, int index) {
    if ((week == 2 || week == 3) && index == 0)
      return 1; // overload the main lift
    if (week == 4) return -1; // deload
    return 0;
  }

  static (int?, int?) nutritionTargets(Profile p) {
    if (p.weightKg == null || p.heightCm == null) return (null, null);
    final s = switch (p.sex) {
      'male' => 5,
      'female' => -161,
      _ => -78,
    };
    final bmr = 10 * p.weightKg! + 6.25 * p.heightCm! - 5 * 30 + s;
    final tdee = bmr * (1.2 + 0.075 * p.daysPerWeek);
    final adj = const {
      Goal.loseFat: -0.2,
      Goal.recomp: -0.05,
      Goal.buildMuscle: 0.1,
      Goal.strength: 0.05,
    }[p.goal]!;
    final kcal = ((math.max(1200, tdee * (1 + adj)) / 10).round() * 10);
    final protein = (p.weightKg! * (p.goal == Goal.strength ? 1.8 : 2.0))
        .round();
    return (kcal, math.min(protein, 300));
  }
}
