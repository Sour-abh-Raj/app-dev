import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/checkin/checkin_wizard.dart';
import '../features/coach/coach_screen.dart';
import '../features/debug/debug_screen.dart';
import '../features/eat/eat_screen.dart';
import '../features/eat/meal_result_screen.dart';
import '../features/exercise/exercise_screen.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/paywall/paywall_screen.dart';
import '../features/preview/preview_screen.dart';
import '../features/progress/progress_screen.dart';
import '../features/redeem/redeem_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/shell.dart';
import '../features/summary/summary_screen.dart';
import '../features/today/today_screen.dart';
import 'providers.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

GoRouter buildRouter(Ref ref) {
  final local = ref.read(servicesProvider).local;
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: local.onboarded ? '/today' : '/onboarding',
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final open =
          loc.startsWith('/onboarding') ||
          loc.startsWith('/paywall') ||
          loc.startsWith('/debug');
      if (!local.onboarded && !open) return '/onboarding';
      return null;
    },
    routes: [
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingFlow()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/today', builder: (_, _) => const TodayScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/eat', builder: (_, _) => const EatScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/progress',
                builder: (_, _) => const ProgressScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/coach', builder: (_, _) => const CoachScreen()),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/exercise/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => ExerciseScreen(
          exId: s.pathParameters['id']!,
          workoutId: s.uri.queryParameters['workout'],
        ),
      ),
      GoRoute(
        path: '/summary/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => SummaryScreen(workoutId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/meal/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => MealResultScreen(mealId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/checkin',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) =>
            CheckinWizard(reportFor: s.uri.queryParameters['report']),
      ),
      GoRoute(
        path: '/preview',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const PreviewScreen(),
      ),
      GoRoute(
        path: '/settings',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/redeem',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, _) => const RedeemScreen(),
      ),
      GoRoute(
        path: '/paywall',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (_, s) => MaterialPage(
          fullscreenDialog: true,
          child: PaywallScreen(
            placement: s.uri.queryParameters['placement'] ?? 'settings',
            next: s.uri.queryParameters['next'],
          ),
        ),
      ),
      if (!kReleaseMode) // O11: debug time controls never ship
        GoRoute(
          path: '/debug',
          parentNavigatorKey: rootNavigatorKey,
          builder: (_, _) => const DebugScreen(),
        ),
    ],
  );
}

final routerProvider = Provider<GoRouter>((ref) => buildRouter(ref));

/// Deep links from notifications ("forme://checkin", "forme://paywall?…").
String? deepLinkToLocation(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null || uri.scheme != 'forme') return null;
  final path = '/${uri.host}${uri.path}';
  const known = [
    '/today',
    '/eat',
    '/progress',
    '/coach',
    '/checkin',
    '/paywall',
    '/settings',
    '/redeem',
    '/preview',
  ];
  final base = known.firstWhere((k) => path.startsWith(k), orElse: () => '');
  if (base.isEmpty)
    return path == '/settings/subscription' ? '/settings' : null;
  return uri.hasQuery ? '$base?${uri.query}' : base;
}
