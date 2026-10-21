import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// O9 mandatory events. Names are the contract with the growth dashboards.
class Events {
  const Events._();
  static const trialStartedWithPhotos = 'trial_started_with_photos';

  /// The "aha" moment: the user's first AI check-in report renders.
  static const conversionEventReached = 'conversion_event_reached';
  static const trialEndPaywallShown = 'trial_end_paywall_shown';
  static const cancelTap = 'cancel_tap';
  static const winbackAccepted = 'winback_accepted';
  static String capHit(String cap) =>
      'cap_hit_$cap'; // cap_hit_meal, cap_hit_chat, …

  // Funnel helpers (not mandatory, but used by the trial→paid kill rule).
  static const paywallShown = 'paywall_shown';
  static const purchaseCompleted = 'purchase_completed';
  static const restoreCompleted = 'restore_completed';
  static const onboardingCompleted = 'onboarding_completed';
  static const workoutFinished = 'workout_finished';
  static const mealLogged = 'meal_logged';
  static const checkinSubmitted = 'checkin_submitted';
  static const promoRedeemed = 'promo_redeemed';
  static const syncConflict = 'sync_conflict';
  static const syncFailed = 'sync_failed';
}

abstract class Analytics {
  Future<void> log(String name, [Map<String, Object>? params]);
  Future<void> setUser(String? uid);
  void recordError(Object error, StackTrace? stack, {String? reason});
}

class FirebaseAnalyticsSink implements Analytics {
  FirebaseAnalyticsSink(this._fa, this._crash);

  final FirebaseAnalytics _fa;
  final FirebaseCrashlytics _crash;

  @override
  Future<void> log(String name, [Map<String, Object>? params]) async {
    try {
      await _fa.logEvent(name: name, parameters: params);
    } catch (e, st) {
      _crash.recordError(e, st, reason: 'analytics');
    }
  }

  @override
  Future<void> setUser(String? uid) async {
    await _fa.setUserId(id: uid);
    await _crash.setUserIdentifier(uid ?? '');
  }

  @override
  void recordError(Object error, StackTrace? stack, {String? reason}) =>
      _crash.recordError(error, stack, reason: reason);
}

/// Demo/test sink: records events in memory and prints them in debug.
class MemoryAnalytics implements Analytics {
  final events = <(String, Map<String, Object>?)>[];
  final errors = <Object>[];

  @override
  Future<void> log(String name, [Map<String, Object>? params]) async {
    events.add((name, params));
    if (kDebugMode) debugPrint('[analytics] $name ${params ?? ''}');
  }

  @override
  Future<void> setUser(String? uid) async {}

  @override
  void recordError(Object error, StackTrace? stack, {String? reason}) {
    errors.add(error);
    if (kDebugMode) debugPrint('[crash] $reason $error');
  }

  bool logged(String name) => events.any((e) => e.$1 == name);
}
