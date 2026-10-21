import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/clock.dart';
import '../data/api/ai_api.dart';
import '../data/local/local_store.dart';
import '../data/remote/remote.dart';
import '../data/repo.dart';
import '../data/sync/outbox.dart';
import '../data/sync/sync_engine.dart';
import '../domain/access.dart';
import '../domain/exercise_library.dart';
import '../domain/models.dart';
import '../services/analytics.dart';
import '../services/auth_service.dart';
import '../services/device_services.dart';
import '../services/photo_service.dart';
import '../services/purchases_service.dart';

/// Everything built once at startup (see bootstrap.dart).
class AppServices {
  AppServices({
    required this.local,
    required this.outbox,
    required this.sync,
    required this.api,
    required this.remote,
    required this.auth,
    required this.purchases,
    required this.analytics,
    required this.notifications,
    required this.health,
    required this.biometric,
    required this.photos,
    required this.lib,
    required this.isOnline,
    required this.onlineChanges,
    this.pose,
    this.remoteConfig = const {},
    this.demo = false,
  });

  final LocalStore local;
  final Outbox outbox;
  final SyncEngine sync;
  final AiApi api;
  final Remote remote;
  final AuthService auth;
  final PurchasesService purchases;
  final Analytics analytics;
  final NotificationService notifications;
  final HealthService health;
  final BiometricService biometric;
  final PhotoService photos;
  final PoseService? pose;
  final ExerciseLibrary lib;
  final Future<bool> Function() isOnline;
  final Stream<bool> onlineChanges;
  final Map<String, String> remoteConfig;
  final bool demo;
}

final servicesProvider = Provider<AppServices>(
  (ref) => throw UnimplementedError('override in main'),
);

final libProvider = Provider<ExerciseLibrary>(
  (ref) => ref.watch(servicesProvider).lib,
);

/// Bumps on every local write, so derived providers re-read Hive.
final localTickProvider = StreamProvider<String>(
  (ref) => ref.watch(servicesProvider).local.changes,
);

final profileProvider = Provider<Profile?>((ref) {
  ref.watch(localTickProvider);
  return ref.watch(servicesProvider).local.profile;
});

final planProvider = Provider<Plan?>((ref) {
  ref.watch(localTickProvider);
  return ref.watch(servicesProvider).local.plan;
});

final workoutsProvider = Provider<List<Workout>>((ref) {
  ref.watch(localTickProvider);
  return ref.watch(servicesProvider).local.workouts;
});

final mealsProvider = Provider<List<Meal>>((ref) {
  ref.watch(localTickProvider);
  return ref.watch(servicesProvider).local.meals;
});

final checkinsProvider = Provider<List<Checkin>>((ref) {
  ref.watch(localTickProvider);
  return ref.watch(servicesProvider).local.checkins;
});

final chatProvider = Provider<List<ChatMessage>>((ref) {
  ref.watch(localTickProvider);
  return ref.watch(servicesProvider).local.chat;
});

final authUserProvider = StreamProvider<AppUser?>((ref) async* {
  final auth = ref.watch(servicesProvider).auth;
  yield auth.current;
  yield* auth.changes;
});

final onlineProvider = StreamProvider<bool>((ref) async* {
  final s = ref.watch(servicesProvider);
  yield await s.isOnline();
  yield* s.onlineChanges;
});

final outboxProvider = StreamProvider<List<OutboxOp>>((ref) async* {
  final o = ref.watch(servicesProvider).outbox;
  yield o.all();
  await for (final _ in o.changed) {
    yield o.all();
  }
});

final repoProvider = Provider<Repo>((ref) {
  final s = ref.watch(servicesProvider);
  return Repo(
    local: s.local,
    outbox: s.outbox,
    sync: s.sync,
    api: s.api,
    lib: s.lib,
    analytics: s.analytics,
    uid: () => s.auth.current?.uid,
    now: () => ref.read(clockProvider).now(),
  );
});

// ---------- entitlement ----------

/// Debug-only overrides for O11 (compiled out of release by kReleaseMode).
class DebugFlags {
  const DebugFlags({this.simulateExpired = false});
  final bool simulateExpired;
}

class DebugFlagsNotifier extends Notifier<DebugFlags> {
  @override
  DebugFlags build() => const DebugFlags();

  void simulateExpiry(bool v) {
    if (kReleaseMode) return;
    state = DebugFlags(simulateExpired: v);
  }
}

final debugFlagsProvider = NotifierProvider<DebugFlagsNotifier, DebugFlags>(
  DebugFlagsNotifier.new,
);

/// Merges RevenueCat CustomerInfo with the server mirror (promo grants,
/// winback eligibility, billing issues) and caches it in Hive so offline
/// launches keep Pro for ≤7 days.
class EntitlementNotifier extends Notifier<Entitlement> {
  StreamSubscription<Entitlement>? _rcSub;
  StreamSubscription<Map<String, dynamic>?>? _mirrorSub;
  Entitlement? _store; // latest RevenueCat CustomerInfo
  Map<String, dynamic>? _mirror; // latest users/{uid} document

  @override
  Entitlement build() {
    final s = ref.watch(servicesProvider);
    final user = ref.watch(authUserProvider).value;
    _rcSub = s.purchases.updates.listen((e) {
      _store = e;
      _combine();
    });
    if (user != null) {
      _mirrorSub = s.remote.userDoc(user.uid).listen((d) {
        _mirror = d;
        _combine();
      }, onError: (_) {});
    }
    ref.onDispose(() {
      _rcSub?.cancel();
      _mirrorSub?.cancel();
    });
    return s.local.entitlement; // cached: offline launches keep Pro ≤7 days
  }

  void _combine() {
    final now = ref.read(clockProvider).now();
    final base = _store ?? state;
    final ent = _mirror?['entitlement'] as Map<String, dynamic>?;
    final wb = _mirror?['winback'] as Map<String, dynamic>?;
    final promoUntil = _date(ent?['promo_expires_at']);
    final promoActive = promoUntil != null && promoUntil.isAfter(now);
    final mirrorPro = ent?['pro'] as bool? ?? false;
    _set(
      base.copyWith(
        pro: (_store?.pro ?? false) || mirrorPro || promoActive,
        promo: promoActive || base.promo,
        billingIssue:
            base.billingIssue || (ent?['billing_issue'] as bool? ?? false),
        everSubscribed:
            base.everSubscribed || ent != null || state.everSubscribed,
        winbackUntil: wb?['eligible'] == true
            ? _date(wb?['until'])
            : state.winbackUntil,
        fetchedAt: now,
      ),
    );
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    try {
      return (v as dynamic)?.toDate() as DateTime?; // Firestore Timestamp
    } catch (_) {
      return null;
    }
  }

  void _set(Entitlement e) {
    state = e;
    unawaited(ref.read(servicesProvider).local.saveEntitlement(e));
  }

  /// Purchase/restore results arrive here before the listener fires.
  void apply(Entitlement e) {
    _store = e;
    _combine();
  }
}

final entitlementProvider = NotifierProvider<EntitlementNotifier, Entitlement>(
  EntitlementNotifier.new,
);

final tierProvider = Provider<Tier>((ref) {
  final e = ref.watch(entitlementProvider);
  final now = ref.watch(clockProvider).now();
  if (!kReleaseMode && ref.watch(debugFlagsProvider).simulateExpired) {
    return Tier.grace;
  }
  return e.tierAt(now);
});

final accessProvider = Provider<Access>(
  (ref) => Access(ref.watch(tierProvider)),
);

final winbackEligibleProvider = Provider<bool>((ref) {
  if (!kReleaseMode && ref.watch(debugFlagsProvider).simulateExpired) {
    return true;
  }
  return ref
      .watch(entitlementProvider)
      .winbackEligible(ref.watch(clockProvider).now());
});
