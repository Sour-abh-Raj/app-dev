import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sync/pull.dart';
import '../services/device_services.dart';
import 'providers.dart';
import 'router.dart';
import 'theme.dart';

class FormeApp extends ConsumerStatefulWidget {
  const FormeApp({super.key});

  @override
  ConsumerState<FormeApp> createState() => _FormeAppState();
}

class _FormeAppState extends ConsumerState<FormeApp>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final s = ref.read(servicesProvider);
    _locked = s.local.profile?.biometricLock ?? false;
    unawaited(
      s.notifications.init(
        onOpen: (link) {
          final loc = deepLinkToLocation(link);
          if (loc != null) ref.read(routerProvider).push(loc);
        },
      ),
    );
    unawaited(s.sync.drain()); // O2: drain on app start
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final s = ref.read(servicesProvider);
    if (state == AppLifecycleState.resumed) {
      unawaited(s.sync.drain());
      if (_locked) _unlock();
    } else if (state == AppLifecycleState.paused &&
        (s.local.profile?.biometricLock ?? false)) {
      setState(() => _locked = true);
    }
  }

  Future<void> _unlock() async {
    if (_unlocking) return;
    _unlocking = true;
    final ok = await ref.read(servicesProvider).biometric.unlock();
    _unlocking = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  Future<void> _onSignedIn(String uid) async {
    final s = ref.read(servicesProvider);
    await s.analytics.setUser(uid);
    try {
      await s.purchases.logIn(uid); // RevenueCat app user id == Firebase uid
    } catch (e, st) {
      s.analytics.recordError(e, st, reason: 'rc login');
    }
    final tz = await s.notifications.localTimezone();
    final token = await s.notifications.fcmToken();
    final profile = s.local.profile;
    final offset = DateTime.now().timeZoneOffset;
    try {
      await s.remote.upsert(uid, '', 'me', {
        'timezone': tz,
        'fcm_tokens': ?(token == null ? null : [token]),
        'checkin_reminder_slot': checkinReminderSlot(
          profile?.checkinReminderHour ?? 9,
          offset,
        ),
      });
      await SyncPull(
        local: s.local,
        remote: s.remote,
        outbox: s.outbox,
        analytics: s.analytics,
      ).run(uid);
    } catch (_) {
      // Offline: the next launch retries; logging works regardless.
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    ref.listen(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value != true) {
        unawaited(
          ref.read(servicesProvider).sync.drain(),
        ); // O2: drain on reconnect
      }
    });
    ref.listen(authUserProvider, (prev, next) {
      final uid = next.value?.uid;
      if (uid != null && uid != prev?.value?.uid) unawaited(_onSignedIn(uid));
    });
    ref.watch(entitlementProvider); // keep the RevenueCat listener alive
    return MaterialApp.router(
      title: 'Forme AI',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (context, child) => Stack(
        children: [
          ?child,
          if (_locked) _LockScreen(onUnlock: _unlock),
        ],
      ),
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) => Material(
    color: Brand.ink,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock, color: Brand.lime, size: 48),
          const SizedBox(height: 12),
          const Text('Forme AI is locked', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 16),
          SizedBox(
            width: 200,
            child: FilledButton(
              onPressed: onUnlock,
              child: const Text('Unlock'),
            ),
          ),
        ],
      ),
    ),
  );
}
