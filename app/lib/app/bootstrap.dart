import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/config.dart';
import '../data/api/ai_api.dart';
import '../data/demo.dart';
import '../data/local/local_store.dart';
import '../data/remote/remote.dart';
import '../data/sync/handlers.dart';
import '../data/sync/outbox.dart';
import '../data/sync/sync_engine.dart';
import '../domain/exercise_library.dart';
import '../services/analytics.dart';
import '../services/auth_service.dart';
import '../services/device_services.dart';
import '../services/photo_service.dart';
import '../services/purchases_service.dart';
import 'providers.dart';

/// Remote Config defaults (paywall copy/variants and the winback code are
/// server-controlled; nothing secret is shipped).
const remoteConfigDefaults = <String, String>{
  'paywall_variant': 'a',
  'winback_offer_code': '',
  'social_proof': '',
  'weekly_entry_geos': '',
};

Future<AppServices> bootstrap() async {
  await Hive.initFlutter();
  final local = await LocalStore.open();
  final lib = await ExerciseLibrary.load();
  if (kReleaseMode &&
      (!AppConfig.hasFirebase || AppConfig.revenueCatKey.isEmpty)) {
    // Never ship fakes: a release build without real config must not start.
    throw StateError('Release build is missing Firebase/RevenueCat config');
  }
  final demo = AppConfig.demoMode || !AppConfig.hasFirebase;

  final connectivity = Connectivity();
  Future<bool> isOnline() async =>
      !(await connectivity.checkConnectivity()).contains(
        ConnectivityResult.none,
      ) ||
      demo;
  final onlineChanges = connectivity.onConnectivityChanged
      .map((r) => !r.contains(ConnectivityResult.none))
      .distinct();

  late final AuthService auth;
  late final AiApi api;
  late final Remote remote;
  late final Analytics analytics;
  late final PurchasesService purchases;
  late final NotificationService notifications;
  var remoteConfig = Map<String, String>.from(remoteConfigDefaults);

  if (demo) {
    // Debug-only path: no credentials needed to click through the app.
    auth = DemoAuthService();
    analytics = MemoryAnalytics();
    remote = DemoRemote();
    final fake = FakePurchasesService();
    purchases = fake;
    api = DemoAiApi(lib, isPro: () => local.entitlement.pro);
    notifications = NoNotifications();
  } else {
    await Firebase.initializeApp(
      options: AppConfig.firebaseOptions(defaultTargetPlatform),
    );
    if (AppConfig.useEmulators) {
      await FirebaseAuth.instance.useAuthEmulator(AppConfig.emulatorHost, 9099);
      FirebaseFirestore.instance.useFirestoreEmulator(
        AppConfig.emulatorHost,
        8080,
      );
      await FirebaseStorage.instance.useStorageEmulator(
        AppConfig.emulatorHost,
        9199,
      );
      FirebaseFunctions.instance.useFunctionsEmulator(
        AppConfig.emulatorHost,
        5001,
      );
    }
    // Crashlytics from build one (O9).
    final crash = FirebaseCrashlytics.instance;
    await crash.setCrashlyticsCollectionEnabled(!kDebugMode);
    FlutterError.onError = crash.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (e, st) {
      crash.recordError(e, st, fatal: true);
      return true;
    };
    analytics = FirebaseAnalyticsSink(FirebaseAnalytics.instance, crash);
    auth = FirebaseAuthService(FirebaseAuth.instance);
    api = HttpAiApi(
      baseUrl: AppConfig.aiBaseUrl,
      idToken: () => auth.idToken(),
    );
    remote = FirebaseRemote(
      FirebaseFirestore.instance,
      FirebaseStorage.instance,
      () => FirebaseFunctions.instance
          .httpsCallable('requestAccountDeletion')
          .call<void>(),
    );
    purchases = AppConfig.revenueCatKey.isNotEmpty
        ? RevenueCatService()
        : FakePurchasesService();
    notifications = PlatformNotificationService();
    // Off the critical path: cold start must stay <2.5 s.
    unawaited(
      purchases.configure().catchError((Object e, StackTrace st) {
        analytics.recordError(e, st, reason: 'revenuecat configure');
      }),
    );
    try {
      final rc = FirebaseRemoteConfig.instance;
      await rc.setDefaults(remoteConfigDefaults);
      unawaited(rc.fetchAndActivate().catchError((_) => false));
      remoteConfig = {
        for (final k in remoteConfigDefaults.keys) k: rc.getString(k),
      };
    } catch (_) {}
  }

  final outbox = Outbox(local.outboxBox);
  late final SyncEngine sync;
  final handlers = SyncHandlers(
    local: local,
    remote: remote,
    api: api,
    uid: () => auth.current?.uid,
    onCapReached: (e) => analytics.log(Events.capHit(e.cap)),
  );
  sync = SyncEngine(
    outbox: outbox,
    handlers: handlers.map,
    isOnline: isOnline,
    onPermanentFailure: (op, err) =>
        analytics.log(Events.syncFailed, {'kind': op.kind, 'error': err}),
  );

  return AppServices(
    local: local,
    outbox: outbox,
    sync: sync,
    api: api,
    remote: remote,
    auth: auth,
    purchases: purchases,
    analytics: analytics,
    notifications: notifications,
    health: demo ? NoHealthService() : PlatformHealthService(),
    biometric: demo ? NoBiometric() : LocalAuthBiometric(),
    photos: PhotoService(),
    pose: demo ? null : PoseService(),
    lib: lib,
    isOnline: isOnline,
    onlineChanges: onlineChanges,
    remoteConfig: remoteConfig,
    demo: demo,
  );
}
