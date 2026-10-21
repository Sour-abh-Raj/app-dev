import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forme/app/providers.dart';
import 'package:forme/app/theme.dart';
import 'package:forme/data/demo.dart';
import 'package:forme/data/local/local_store.dart';
import 'package:forme/data/sync/handlers.dart';
import 'package:forme/data/sync/outbox.dart';
import 'package:forme/data/sync/sync_engine.dart';
import 'package:forme/services/analytics.dart';
import 'package:forme/services/auth_service.dart';
import 'package:forme/services/device_services.dart';
import 'package:forme/services/photo_service.dart';
import 'package:forme/services/purchases_service.dart';
import 'package:go_router/go_router.dart';

import '../helpers.dart';

class TestEnv {
  TestEnv(this.services, this.purchases, this.analytics, this.api);
  final AppServices services;
  final FakePurchasesService purchases;
  final MemoryAnalytics analytics;
  final DemoAiApi api;
}

int _n = 0;

Future<TestEnv> makeEnv({bool pro = false}) async {
  final local = await LocalStore.open(prefix: 'w${_n++}_');
  final lib = loadLib();
  final analytics = MemoryAnalytics();
  final purchases = FakePurchasesService();
  final api = DemoAiApi(
    lib,
    isPro: () => local.entitlement.pro,
    latency: Duration.zero,
  );
  final remote = DemoRemote();
  final auth = DemoAuthService();
  await auth.signInWithEmail('t@forme.ai', 'password1', create: true);
  final outbox = Outbox(local.outboxBox);
  final sync = SyncEngine(
    outbox: outbox,
    isOnline: () async => true,
    handlers: SyncHandlers(
      local: local,
      remote: remote,
      api: api,
      uid: () => 'demo-user',
    ).map,
  );
  final services = AppServices(
    local: local,
    outbox: outbox,
    sync: sync,
    api: api,
    remote: remote,
    auth: auth,
    purchases: purchases,
    analytics: analytics,
    notifications: NoNotifications(),
    health: NoHealthService(),
    biometric: NoBiometric(),
    photos: PhotoService(),
    lib: lib,
    isOnline: () async => true,
    onlineChanges: const Stream<bool>.empty(),
    demo: true,
  );
  return TestEnv(services, purchases, analytics, api);
}

/// Pumps [child] inside a router (so `context.push` works) with the services.
Future<void> pumpScreen(
  WidgetTester tester,
  TestEnv env,
  Widget child, {
  List<RouteBase> extra = const [],
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: child),
      ),
      GoRoute(
        path: '/paywall',
        builder: (_, s) =>
            Text('PAYWALL ${s.uri.queryParameters['placement']}'),
      ),
      GoRoute(
        path: '/summary/:id',
        builder: (_, s) => Text('SUMMARY ${s.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/meal/:id',
        builder: (_, s) => Text('MEAL ${s.pathParameters['id']}'),
      ),
      GoRoute(path: '/checkin', builder: (_, _) => const Text('CHECKIN')),
      GoRoute(path: '/today', builder: (_, _) => const Text('TODAY')),
      GoRoute(path: '/redeem', builder: (_, _) => const Text('REDEEM')),
      GoRoute(path: '/settings', builder: (_, _) => const Text('SETTINGS')),
      GoRoute(
        path: '/exercise/:id',
        builder: (_, s) => Text('EXERCISE ${s.pathParameters['id']}'),
      ),
      ...extra,
    ],
  );
  await tester.pumpWidget(
    const SizedBox(),
  ); // fresh ProviderContainer per screen
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(env.services)],
      child: MaterialApp.router(theme: buildTheme(), routerConfig: router),
    ),
  );
  await tester.pump();
}

/// Runs async Hive I/O that `pump` alone does not advance.
/// Hive completes real file I/O; each await hop needs a real-time slice plus
/// a pump to run its continuation in the test zone.
Future<void> settle(WidgetTester tester, {int hops = 12}) async {
  for (var i = 0; i < hops; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
