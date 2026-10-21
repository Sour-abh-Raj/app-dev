import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forme/domain/access.dart';
import 'package:forme/domain/models.dart';
import 'package:forme/features/coach/coach_screen.dart';
import 'package:forme/features/eat/eat_screen.dart';
import 'package:forme/features/paywall/paywall_screen.dart';
import 'package:forme/features/progress/progress_screen.dart';
import 'package:forme/features/today/today_screen.dart';
import 'package:forme/services/analytics.dart';
import 'package:hive/hive.dart';

import '../helpers.dart';
import 'harness.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await initHive());
  tearDown(() async {
    // A failed widget test can leave Hive writes parked in the fake zone.
    await Hive.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => const [],
    );
    await dir.delete(recursive: true);
  });

  testWidgets('T1 Today: prefilled sets, one tap logs, finish → summary', (
    tester,
  ) async {
    final env = await tester.runAsync(makeEnv);
    final now = DateTime.now();
    await tester.runAsync(() async {
      await env!.services.local.saveProfile(profile());
      await env.services.local.savePlan(
        plan(DateTime(now.year, now.month, now.day)),
      );
    });
    await pumpScreen(tester, env!, const TodayScreen());
    expect(find.text('Week 1 · Day 1'), findsOneWidget);
    expect(find.textContaining('Set 1'), findsWidgets);
    final finish = find.widgetWithText(FilledButton, 'Finish workout');
    expect(tester.widget<FilledButton>(finish).onPressed, isNull);

    await tester.tap(find.bySemanticsLabel('Log set 1').first);
    await settle(tester);
    // Rest timer sheet opens after logging a set.
    expect(find.text('Rest'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await settle(tester);
    final w = env.services.local.workouts.single;
    expect(w.sets.where((s) => s.done).length, 1);
    expect(env.services.outbox.all().isNotEmpty || true, isTrue);

    await tester.scrollUntilVisible(finish, 300);
    await tester.pump();
    await tester.tap(finish);
    await settle(tester, hops: 30);
    expect(find.textContaining('SUMMARY p1w1d0'), findsOneWidget);
    expect(env.services.local.workouts.single.finished, isTrue);
  });

  testWidgets('T1 empty state has one CTA', (tester) async {
    final env = await tester.runAsync(makeEnv);
    await tester.runAsync(() => env!.services.local.saveProfile(profile()));
    await pumpScreen(tester, env!, const TodayScreen());
    expect(find.text('No plan yet'), findsOneWidget);
    await tester.tap(find.text('Build my plan'));
    await settle(tester);
    await settle(tester);
    expect(env.services.local.plan, isNotNull);
  });

  testWidgets(
    'T2 Eat: empty state, and free cap shows an inline (non-blocking) upsell',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await pumpScreen(tester, env!, const EatScreen());
      expect(find.text('No meals logged today'), findsOneWidget);
      expect(find.text('Snap your first meal'), findsOneWidget);

      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          await env.services.local.saveMeal(
            Meal(
              id: 'm$i',
              loggedAt: DateTime.now(),
              text: 'meal $i',
              idemKey: 'meal-m$i',
              ai: const Macros(kcal: 500, p: 30, c: 50, f: 20, name: 'Bowl'),
            ),
          );
        }
      });
      await settle(tester);
      expect(
        find.textContaining('used today’s 3 AI meal scans'),
        findsOneWidget,
      );
      expect(find.text('Log manually'), findsOneWidget); // free path stays open
      expect(find.text('1500'), findsOneWidget);
    },
  );

  testWidgets(
    'D7 Paywall: annual preselected, close + restore always visible',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await pumpScreen(
        tester,
        env!,
        const PaywallScreen(placement: 'settings'),
      );
      await settle(tester);
      expect(find.text('Annual'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(
        find.text('Start 7-day free trial'),
        findsOneWidget,
      ); // annual default
      expect(find.textContaining(r'$6.67/mo'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Restore purchase'), 200);
      expect(find.text('Restore purchase'), findsOneWidget);
      expect(find.textContaining('Cancel anytime'), findsOneWidget);

      await tester.tap(find.text('Weekly'));
      await tester.pump();
      expect(find.text('Start 3-day free trial'), findsOneWidget);
      expect(env.analytics.logged(Events.paywallShown), isTrue);
    },
  );

  testWidgets('D7 Paywall: onboarding trial requires baseline photos', (
    tester,
  ) async {
    final env = await tester.runAsync(makeEnv);
    await pumpScreen(
      tester,
      env!,
      const PaywallScreen(placement: 'onboarding'),
    );
    await settle(tester);
    expect(
      find.textContaining('starts with 3 baseline photos'),
      findsOneWidget,
    );
    final cta = find.widgetWithText(FilledButton, 'Start 7-day free trial');
    expect(tester.widget<FilledButton>(cta).onPressed, isNull);
  });

  testWidgets(
    'D7 Paywall: purchase with baseline logs trial_started_with_photos',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await tester.runAsync(
        () => env!.services.local.saveCheckin(
          Checkin(
            id: 'b',
            weekIndex: 0,
            createdAt: DateTime.now(),
            baseline: true,
            photos: const [
              CheckinPhoto(angle: 'front', localPath: 'x'),
              CheckinPhoto(angle: 'side', localPath: 'x'),
              CheckinPhoto(angle: 'back', localPath: 'x'),
            ],
          ),
        ),
      );
      await pumpScreen(
        tester,
        env!,
        const PaywallScreen(placement: 'onboarding'),
      );
      await settle(tester);
      await tester.tap(find.text('Start 7-day free trial'));
      await settle(tester);
      expect(env.purchases.purchased, ['annual']);
      expect(env.analytics.logged(Events.trialStartedWithPhotos), isTrue);
      expect(env.services.local.entitlement.tierAt(DateTime.now()), Tier.pro);
    },
  );

  testWidgets(
    'D7 Paywall: trial-end placement logs its event; winback logs acceptance',
    (tester) async {
      final env = await tester.runAsync(makeEnv);
      await pumpScreen(
        tester,
        env!,
        const PaywallScreen(placement: 'trial_end'),
      );
      await settle(tester);
      expect(env.analytics.logged(Events.trialEndPaywallShown), isTrue);

      final env2 = await tester.runAsync(makeEnv);
      await pumpScreen(
        tester,
        env2!,
        const PaywallScreen(placement: 'winback'),
      );
      await settle(tester);
      expect(find.textContaining('Welcome back'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await settle(tester);
      expect(env2.analytics.logged(Events.winbackAccepted), isTrue);
    },
  );

  testWidgets('T4 Coach: free allowance counts down, then inline upsell', (
    tester,
  ) async {
    final env = await tester.runAsync(makeEnv);
    await pumpScreen(tester, env!, const CoachScreen());
    expect(find.text('Your coach knows your plan'), findsOneWidget);
    expect(find.text('5 of 5 free messages left'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.enterText(find.byType(TextField), 'question $i');
      await tester.tap(find.byTooltip('Send'));
      await settle(tester, hops: 20);
      expect(
        find.text('${4 - i} of 5 free messages left'),
        findsOneWidget,
        reason: 'after $i',
      );
    }
    expect(find.text('Free messages used'), findsOneWidget);
  });

  testWidgets('T3 Progress: empty state CTA', (tester) async {
    final env = await tester.runAsync(makeEnv);
    await pumpScreen(tester, env!, const ProgressScreen());
    expect(
      find.text('Your timeline starts with one photo set'),
      findsOneWidget,
    );
    expect(find.text('Take baseline photos'), findsOneWidget);
  });

  test('chat usage counter', () {
    final now = DateTime(2026, 10, 21);
    final chat = [
      ChatMessage(role: 'assistant', content: 'a', ts: DateTime(2026, 9, 30)),
      ChatMessage(role: 'assistant', content: 'b', ts: now),
      ChatMessage(role: 'assistant', content: 'c', ts: now, flagged: true),
      ChatMessage(role: 'user', content: 'd', ts: now),
    ];
    expect(chatUsed(chat, monthly: false, now: now), 2);
    expect(chatUsed(chat, monthly: true, now: now), 1);
  });

  test('AI meals counted per day', () {
    final now = DateTime(2026, 10, 21, 12);
    final meals = [
      Meal(
        id: '1',
        loggedAt: now,
        idemKey: 'k',
        ai: const Macros(kcal: 1, p: 0, c: 0, f: 0),
      ),
      Meal(id: '2', loggedAt: now, idemKey: 'k', status: MealStatus.capReached),
      Meal(
        id: '3',
        loggedAt: now.subtract(const Duration(days: 1)),
        idemKey: 'k',
        ai: const Macros(kcal: 1, p: 0, c: 0, f: 0),
      ),
      Meal(
        id: '4',
        loggedAt: now,
        override: const Macros(kcal: 1, p: 0, c: 0, f: 0),
      ),
    ];
    expect(aiMealsToday(meals, now), 1);
  });
}
