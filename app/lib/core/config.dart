import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Build-time configuration, passed with
/// `--dart-define-from-file=config/<flavor>.json`. Only public client keys live
/// here (Firebase web/app keys and RevenueCat public SDK keys are designed to
/// ship in apps); every secret stays server-side.
class AppConfig {
  const AppConfig._();

  static const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'dev');
  static const aiBaseUrl = String.fromEnvironment(
    'AI_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  static const rcIosKey = String.fromEnvironment('RC_IOS_KEY');
  static const rcAndroidKey = String.fromEnvironment('RC_ANDROID_KEY');
  static const googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );
  static const useEmulators = bool.fromEnvironment('USE_EMULATORS');
  static const emulatorHost = String.fromEnvironment(
    'EMULATOR_HOST',
    defaultValue: '10.0.2.2',
  );

  /// Offline demo: local fakes instead of Firebase/RevenueCat/AI service.
  /// Debug builds only — release builds always use the real backends.
  static const _demoFlag = bool.fromEnvironment('DEMO_MODE');
  static bool get demoMode => _demoFlag && !kReleaseMode;

  static const _fbApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _fbProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _fbSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _fbBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
  static const _fbAppIdIos = String.fromEnvironment('FIREBASE_APP_ID_IOS');
  static const _fbAppIdAndroid = String.fromEnvironment(
    'FIREBASE_APP_ID_ANDROID',
  );
  static const _iosBundleId = String.fromEnvironment(
    'IOS_BUNDLE_ID',
    defaultValue: 'ai.forme.app',
  );

  static bool get hasFirebase =>
      _fbApiKey.isNotEmpty && _fbProjectId.isNotEmpty;

  static FirebaseOptions firebaseOptions(TargetPlatform platform) =>
      FirebaseOptions(
        apiKey: _fbApiKey,
        appId: platform == TargetPlatform.iOS ? _fbAppIdIos : _fbAppIdAndroid,
        messagingSenderId: _fbSenderId,
        projectId: _fbProjectId,
        storageBucket: _fbBucket,
        iosBundleId: _iosBundleId,
      );

  static String get revenueCatKey =>
      defaultTargetPlatform == TargetPlatform.iOS ? rcIosKey : rcAndroidKey;
}
