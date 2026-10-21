import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forme/domain/models.dart';
import 'package:forme/domain/plan_engine.dart';

import '../helpers.dart';

void main() {
  final lib = loadLib();
  final engine = PlanEngine(lib);

  test('library has 60 exercises and every substitution resolves', () {
    expect(lib.all.length, 60);
    for (final e in lib.all) {
      for (final s in e.substitutions) {
        expect(lib[s], isNotNull, reason: '${e.id} → $s');
      }
    }
  });

  test(
    'Dart template planner matches the Python fallback exactly (golden)',
    () {
      final golden = jsonDecode(
        File('test/fixtures/template_golden.json').readAsStringSync(),
      ) as List;
      for (final g in golden.cast<Map<String, dynamic>>()) {
        final i = g['input'] as Map<String, dynamic>;
        final p = Profile(
          goal: GoalX.fromWire(i['goal'] as String),
          level: levelFromWire(i['level'] as String),
          equipment: List<String>.from(i['equipment'] as List),
          daysPerWeek: i['days_per_week'] as int,
          mins: i['mins'] as int,
          injuries: List<String>.from(i['injuries'] as List),
          sex: i['sex'] as String?,
          heightCm: (i['height_cm'] as num?)?.toDouble(),
          weightKg: (i['weight_kg'] as num?)?.toDouble(),
        );
        final dart = engine.template(p).toJson();
        final py = g['plan'] as Map<String, dynamic>;
        expect(
          jsonEncode(dart['weeks']),
          jsonEncode(py['weeks']),
          reason: i.toString(),
        );
        expect(dart['kcal_target'], py['kcal_target'], reason: i.toString());
        expect(dart['protein_g'], py['protein_g']);
        expect(dart['name'], py['name']);
      }
    },
  );

  test('respects equipment and injuries', () {
    final m = engine.template(
      profile(equipment: ['bodyweight'], injuries: ['knee', 'wrist']),
    );
    for (final w in m.weeks) {
      for (final s in w.sessions) {
        for (final e in s.exercises) {
          final ex = lib[e.exId]!;
          expect(ex.needs, isEmpty, reason: e.exId);
          expect(
            ex.contraindications.where(['knee', 'wrist'].contains),
            isEmpty,
            reason: e.exId,
          );
        }
      }
    }
  });

  test('progression then deload', () {
    final m = engine.template(profile());
    final w1 = m.weeks[0].sessions[0].exercises,
        w2 = m.weeks[1].sessions[0].exercises;
    final w4 = m.weeks[3].sessions[0].exercises;
    expect(w2[0].sets, w1[0].sets + 1);
    expect(w4[1].sets, w1[1].sets - 1);
  });

  test('session count and slot count follow schedule', () {
    for (final d in [2, 3, 4, 5, 6]) {
      expect(engine.template(profile(days: d)).weeks.first.sessions.length, d);
    }
    expect(PlanEngine.slotsForMinutes(20), 4);
    expect(PlanEngine.slotsForMinutes(40), 5);
    expect(PlanEngine.slotsForMinutes(60), 6);
    expect(PlanEngine.slotsForMinutes(80), 7);
  });

  test('nutrition targets need height and weight', () {
    expect(PlanEngine.nutritionTargets(Profile()), (null, null));
    final (kcal, protein) = PlanEngine.nutritionTargets(profile());
    expect(kcal, greaterThan(1500));
    expect(protein, 164);
  });

  test('substitutes respect constraints', () {
    final subs = lib.substitutesFor('goblet_squat', {'dumbbells'}, {'knee'});
    expect(subs.every((e) => !e.contraindications.contains('knee')), isTrue);
    expect(subs.every((e) => {'dumbbells'}.containsAll(e.needs)), isTrue);
    expect(lib.substitutesFor('nope', {}, {}), isEmpty);
    expect(lib.nameOf('goblet_squat'), 'Goblet squat');
    expect(lib.nameOf('x'), 'x');
  });
}
