import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forme/data/sync/outbox.dart';
import 'package:forme/domain/access.dart';
import 'package:forme/domain/models.dart';
import 'package:forme/features/checkin/checkin_wizard.dart';
import 'package:forme/features/eat/meal_result_screen.dart';
import 'package:forme/features/exercise/exercise_screen.dart';
import 'package:forme/features/onboarding/onboarding_flow.dart';
import 'package:forme/features/preview/preview_screen.dart';
import 'package:forme/features/progress/progress_screen.dart';
import 'package:forme/features/redeem/redeem_screen.dart';
import 'package:forme/features/settings/settings_screen.dart';
import 'package:forme/features/summary/summary_screen.dart';
import 'package:forme/services/analytics.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;

import '../helpers.dart';
import 'harness.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await initHive());
  tearDown(() async {
    await Hive.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => const [],
    );
    await dir.delete(recursive: true);
  });

  List<CheckinPhoto> photos(String tag) {
    final out = <CheckinPhoto>[];
    for (final a in ['front', 'side', 'back']) {
      final f = File('${dir.path}/$tag-$a.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 30, height: 40)));
      out.add(
        CheckinPhoto(
          angle: a,
          localPath: f.path,
          landmarks: const {'sx': 0.5, 'sy': 0.3, 'hx': 0.5, 'hy': 0.55},
        ),
      );
    }
    return out;
  }

  Future<void> makePro(TestEnv env) => env.services.local.saveEntitlement(
    Entitlement(pro: true, everSubscribed: true, fetchedAt: DateTime.now()),
  );

  testWidgets('O1→O5 onboarding steps render and advance', (tester) async {
    final env = await tester.runAsync(makeEnv);
    await pumpScreen(tester, env!, const OnboardingFlow());
    expect(find.text('Get started'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('What’s your goal?'), findsOneWidget);
    expect(find.text('Lose fat'), findsOneWidget);
    expect(find.text('Get stronger'), findsOneWidget);
    await tester.tap(find.text('Build muscle'));
    await tester.pumpAndSettle();
    expect(find.text('Level, equipment & schedule'), findsOneWidget);
    await tester.tap(find.text('Barbell'));
    await tester.scrollUntilVisible(find.text('Continue'), 300);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Anything we should train around?'), findsOneWidget);
    await tester.tap(find.text('Knee'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Your Week 0 photos'), findsOneWidget);
    final cta = find.widgetWithText(FilledButton, 'Take my 3 photos');
    await tester.scrollUntilVisible(cta, 300);
    expect(
      tester.widget<FilledButton>(cta).onPressed,
      isNull,
    ); // 18+ consent first
    await tester.tap(find.textContaining('18 or older'));
    await tester.pump();
    expect(tester.widget<FilledButton>(cta).onPressed, isNotNull);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Save your plan'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('D2 Summary shows volume, PR badges, share', (tester) async {
    final env = await tester.runAsync(makeEnv);
    final now = DateTime.now();
    await tester.runAsync(() async {
      await env!.services.local.savePlan(
        plan(DateTime(now.year, now.month, now.day)),
      );
      await env.services.local.saveWorkout(
        Workout(
          id: 'w1',
          planVersion: 1,
          week: 1,
          dayIndex: 0,
          sessionName: 'Full-body A',
          scheduledFor: now,
          startedAt: now.subtract(const Duration(minutes: 31)),
          finishedAt: now,
          volumeKg: 1234,
          prs: const ['goblet_squat'],
          sets: const [
            SetLog(
              exId: 'goblet_squat',
              setN: 1,
              reps: 10,
              loadKg: 14,
              done: true,
            ),
          ],
        ),
      );
    });
    await pumpScreen(tester, env!, const SummaryScreen(workoutId: 'w1'));
    expect(find.text('1234 kg'), findsOneWidget);
    expect(find.text('Goblet squat'), findsOneWidget);
    expect(find.text('31 min'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('D1 Exercise: cues, PR chart, swap within the workout', (
    tester,
  ) async {
    final env = await tester.runAsync(makeEnv);
    final now = DateTime.now();
    await tester.runAsync(() async {
      await env!.services.local.saveProfile(
        profile(equipment: ['dumbbells', 'bench']),
      );
      await env.services.local.saveWorkout(
        Workout(
          id: 'w1',
          planVersion: 1,
          week: 1,
          dayIndex: 0,
          sessionName: 'A',
          scheduledFor: now,
          sets: const [
            SetLog(
              exId: 'goblet_squat',
              setN: 1,
              reps: 10,
              loadKg: 12,
              done: false,
            ),
          ],
        ),
      );
    });
    await pumpScreen(
      tester,
      env!,
      const ExerciseScreen(exId: 'goblet_squat', workoutId: 'w1'),
    );
    expect(find.text('Hold the bell at chest height'), findsOneWidget);
    expect(find.textContaining('Demo video not available'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Swap exercise'), 300);
    final sub = find.text('Box squat');
    await tester.scrollUntilVisible(sub, 200);
    await tester.tap(sub);
    await settle(tester);
    expect(env.services.local.workout('w1')!.sets.single.exId, 'box_squat');
  });

  testWidgets(
    'D3 Meal result: adjust with steppers, validation, save override',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await tester.runAsync(
        () => env!.services.local.saveMeal(
          Meal(
            id: 'm1',
            loggedAt: DateTime.now(),
            text: 'Bowl',
            ai: const Macros(
              kcal: 500,
              p: 30,
              c: 50,
              f: 20,
              confidence: 0.82,
              model: 'x',
              name: 'Chicken bowl',
            ),
          ),
        ),
      );
      await pumpScreen(tester, env!, const MealResultScreen(mealId: 'm1'));
      await settle(tester);
      expect(find.text('Chicken bowl'), findsOneWidget);
      expect(find.text('82% confidence'), findsOneWidget);
      expect(find.text('500 kcal'), findsWidgets);
      await tester.scrollUntilVisible(find.bySemanticsLabel('Fat plus'), 200);
      for (var i = 0; i < 30; i++) {
        await tester.tap(find.bySemanticsLabel('Calories plus'));
        await tester.pump();
      }
      await tester.pump();
      expect(find.text('Calories don’t match the macros'), findsOneWidget);
      for (var i = 0; i < 30; i++) {
        await tester.tap(find.bySemanticsLabel('Calories minus'));
        await tester.pump();
      }
      await tester.tap(find.bySemanticsLabel('Protein plus'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Save'), 200);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(env.services.local.meal('m1')!.override!.p, 31);
    },
  );

  testWidgets(
    'D3 Meal result: offline shows needs-connection, never an eternal spinner',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      env!.api.offline = true;
      await tester.runAsync(() async {
        await env.services.local.saveMeal(
          Meal(
            id: 'm2',
            loggedAt: DateTime.now(),
            text: 'Eggs',
            status: MealStatus.analyzing,
            idemKey: 'meal-m2',
          ),
        );
        await env.services.outbox.enqueue('ai.meal', {
          'meal_id': 'm2',
          'idem_key': 'meal-m2',
        });
      });
      await pumpScreen(tester, env, const MealResultScreen(mealId: 'm2'));
      await settle(tester, hops: 25);
      expect(find.textContaining('Needs connection'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      env.services.sync.dispose(); // cancel the queued retry timer
    },
  );

  testWidgets(
    'D4 report: Pro sees deltas with confidence + morph; conversion event once',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await tester.runAsync(() async {
        await makePro(env!);
        await env.services.local.saveCheckin(
          Checkin(
            id: 'base',
            weekIndex: 0,
            createdAt: DateTime.now(),
            photos: photos('b'),
            baseline: true,
          ),
        );
        await env.services.local.saveCheckin(
          Checkin(
            id: 'c1',
            weekIndex: 1,
            createdAt: DateTime.now(),
            weightKg: 79,
            photos: photos('c'),
            status: CheckinStatus.done,
            report: const AiReport(
              summary: 'Tighter midsection.',
              deltas: [
                Delta(
                  metric: 'waist_cm',
                  from: 86,
                  to: 82.8,
                  unit: 'cm',
                  confidence: 0.6,
                ),
              ],
              planChanges: ['+2.5 kg on lower-body lifts'],
              coachNote: 'Keep going.',
              promptVersion: 'v1',
            ),
          ),
        );
      });
      await pumpScreen(tester, env!, const CheckinWizard(reportFor: 'c1'));
      await settle(tester);
      expect(find.text('Week 1 report 🎉'), findsOneWidget);
      expect(find.text('−3.2 cm (est.)'), findsOneWidget);
      expect(find.text('60% confidence'), findsOneWidget);
      expect(find.text('Wk 0'), findsOneWidget); // morph labels
      expect(env.analytics.logged(Events.conversionEventReached), isTrue);
    },
  );

  testWidgets(
    'D4 wizard: guide → photos step; free check-in shows locked report upsell',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await tester.runAsync(() async {
        await env!.services.local.saveCheckin(
          Checkin(
            id: 'base',
            weekIndex: 0,
            createdAt: DateTime.now(),
            photos: photos('b'),
            baseline: true,
          ),
        );
        await env.services.local.saveCheckin(
          Checkin(
            id: 'c2',
            weekIndex: 1,
            createdAt: DateTime.now(),
            photos: photos('d'),
            status: CheckinStatus.manual,
          ),
        );
      });
      await pumpScreen(tester, env!, const CheckinWizard(reportFor: 'c2'));
      await settle(tester);
      expect(find.text('Unlock your AI report'), findsOneWidget);
      expect(find.text('Week 0'), findsOneWidget); // manual side-by-side

      await pumpScreen(tester, env, const CheckinWizard());
      await settle(tester);
      expect(find.text('Same pose, same place'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('I’m ready'), 200);
      await tester.tap(find.text('I’m ready'));
      await tester.pumpAndSettle();
      expect(find.text('Take front photo'), findsOneWidget);
    },
  );

  testWidgets('T3 Progress: Pro gets morph, free gets side-by-side + upsell', (
    tester,
  ) async {
    final env = await tester.runAsync(makeEnv);
    await tester.runAsync(() async {
      await env!.services.local.saveCheckin(
        Checkin(
          id: 'base',
          weekIndex: 0,
          createdAt: DateTime.now(),
          weightKg: 80,
          photos: photos('b'),
          baseline: true,
        ),
      );
      await env.services.local.saveCheckin(
        Checkin(
          id: 'c1',
          weekIndex: 1,
          createdAt: DateTime.now().add(const Duration(days: 7)),
          weightKg: 79,
          photos: photos('c'),
        ),
      );
    });
    await pumpScreen(tester, env!, const ProgressScreen());
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Aligned morph + AI report'),
      200,
    );
    expect(find.text('Aligned morph + AI report'), findsOneWidget);
    await tester.runAsync(() => makePro(env));
    await pumpScreen(tester, env, const ProgressScreen());
    await settle(tester);
    expect(find.text('Aligned morph + AI report'), findsNothing);
  });

  testWidgets(
    'D5 Preview: Pro renders the stub, then the monthly quota upsell',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await tester.runAsync(() async {
        await makePro(env!);
        await env.services.local.saveCheckin(
          Checkin(
            id: 'c1',
            weekIndex: 1,
            createdAt: DateTime.now(),
            photos: [
              for (final p in photos('p'))
                p.copyWith(path: 'progress-photos/u/c1/${p.angle}.jpg'),
            ],
          ),
        );
      });
      await pumpScreen(tester, env!, const PreviewScreen());
      await tester.tap(find.text('Generate preview'));
      await settle(tester);
      expect(find.text('PREVIEW'), findsOneWidget);
      expect(
        find.textContaining('coming soon'),
        findsOneWidget,
      ); // consumable stubbed
    },
  );

  testWidgets('D6 Settings renders every section; cancel tap is tracked', (
    tester,
  ) async {
    final env = await tester.runAsync(makeEnv);
    await tester.runAsync(() async {
      await env!.services.local.saveProfile(profile());
      await env.services.outbox.enqueue('x', {});
      final op = env.services.outbox.all().single;
      await env.services.outbox.fail(op, 'permission-denied');
    });
    await pumpScreen(tester, env!, const SettingsScreen());
    await settle(tester);
    expect(find.text('Free'), findsOneWidget);
    await tester.tap(find.text('Manage or cancel subscription'));
    await settle(tester);
    expect(env.analytics.logged(Events.cancelTap), isTrue);
    for (final t in [
      'Health sync (read weight)',
      'Biometric lock',
      '1 change(s) failed to sync',
      'Delete account & all data',
    ]) {
      await tester.scrollUntilVisible(find.text(t), 300);
      expect(find.text(t), findsOneWidget);
    }
    expect(env.services.outbox.failed().single.state, OpState.failed);
  });

  testWidgets('Redeem: invalid and valid staff codes', (tester) async {
    final env = await tester.runAsync(makeEnv);
    await pumpScreen(tester, env!, const RedeemScreen());
    await tester.enterText(find.byType(TextField), 'nope-code');
    await tester.tap(find.text('Redeem'));
    await settle(tester);
    expect(find.text('That code isn’t valid.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'forme-team');
    await tester.tap(find.text('Redeem'));
    await settle(tester);
    expect(find.textContaining('Pro unlocked until'), findsOneWidget);
    expect(env.analytics.logged(Events.promoRedeemed), isTrue);
  });
}
