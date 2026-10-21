import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:health/health.dart';
import 'package:local_auth/local_auth.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Health sync — read-only (weight). Apple Health / Health Connect.
abstract class HealthService {
  Future<bool> requestAccess();
  Future<double?> latestWeightKg();
}

class PlatformHealthService implements HealthService {
  final _health = Health();
  bool _configured = false;
  static const _types = [HealthDataType.WEIGHT];

  Future<void> _ensure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<bool> requestAccess() async {
    try {
      await _ensure();
      return await _health.requestAuthorization(
        _types,
        permissions: [HealthDataAccess.READ],
      );
    } catch (e) {
      debugPrint('health access failed: $e');
      return false;
    }
  }

  @override
  Future<double?> latestWeightKg() async {
    try {
      await _ensure();
      final now = DateTime.now();
      final pts = await _health.getHealthDataFromTypes(
        types: _types,
        startTime: now.subtract(const Duration(days: 14)),
        endTime: now,
      );
      if (pts.isEmpty) return null;
      pts.sort((a, b) => b.dateTo.compareTo(a.dateTo));
      final v = pts.first.value;
      return v is NumericHealthValue ? v.numericValue.toDouble() : null;
    } catch (e) {
      debugPrint('health read failed: $e');
      return null;
    }
  }
}

class NoHealthService implements HealthService {
  @override
  Future<bool> requestAccess() async => false;
  @override
  Future<double?> latestWeightKg() async => null;
}

/// Biometric/passcode lock for the app (protects progress photos).
abstract class BiometricService {
  Future<bool> available();
  Future<bool> unlock();
}

class LocalAuthBiometric implements BiometricService {
  final _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> unlock() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Forme AI to see your progress',
      );
    } catch (_) {
      return false;
    }
  }
}

class NoBiometric implements BiometricService {
  @override
  Future<bool> available() async => false;
  @override
  Future<bool> unlock() async => true;
}

/// Local reminders (offline-capable) + FCM token registration for server
/// pushes (trial nudges, winback, fix-payment, Sunday check-in).
abstract class NotificationService {
  Future<void> init({required void Function(String link) onOpen});
  Future<bool> requestPermission();
  Future<void> scheduleWorkoutReminders({
    required int hour,
    required List<int> weekdays,
  });
  Future<void> scheduleCatchup(DateTime at);
  Future<String?> fcmToken();
  Future<String> localTimezone();
}

class PlatformNotificationService implements NotificationService {
  final _local = FlutterLocalNotificationsPlugin();
  FirebaseMessaging? _fcm;
  static const _channel = AndroidNotificationDetails(
    'reminders',
    'Reminders',
    channelDescription: 'Workout and check-in reminders',
    importance: Importance.defaultImportance,
  );
  static const _details = NotificationDetails(
    android: _channel,
    iOS: DarwinNotificationDetails(),
  );

  @override
  Future<void> init({required void Function(String link) onOpen}) async {
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(await localTimezone()));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null) onOpen(r.payload!);
      },
    );
    try {
      _fcm = FirebaseMessaging.instance;
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        final link = m.data['link'];
        if (link is String) onOpen(link);
      });
      final initial = await _fcm!.getInitialMessage();
      final link = initial?.data['link'];
      if (link is String) onOpen(link);
    } catch (e) {
      debugPrint('fcm unavailable: $e');
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      final ok = await _local
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _fcm?.requestPermission();
      return ok ?? false;
    }
    final ok = await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    return ok ?? false;
  }

  @override
  Future<void> scheduleWorkoutReminders({
    required int hour,
    required List<int> weekdays,
  }) async {
    for (var id = 100; id < 107; id++) {
      await _local.cancel(id: id);
    }
    final now = tz.TZDateTime.now(tz.local);
    for (final wd in weekdays) {
      var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour);
      while (at.weekday != wd || at.isBefore(now)) {
        at = at.add(const Duration(days: 1));
      }
      await _local.zonedSchedule(
        id: 100 + wd - 1,
        title: 'Today’s workout is ready',
        body: 'Prefilled and waiting — one tap per set.',
        scheduledDate: at,
        notificationDetails: _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: 'forme://today',
      );
    }
  }

  @override
  Future<void> scheduleCatchup(DateTime at) async {
    await _local.cancel(id: 200);
    await _local.zonedSchedule(
      id: 200,
      title: '20-min catch-up?',
      body: 'A short version of the session you missed. Still counts.',
      scheduledDate: tz.TZDateTime.from(at, tz.local),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'forme://today',
    );
  }

  @override
  Future<String?> fcmToken() async {
    try {
      // FCM registration token for the Admin SDK multicast in Functions.
      // ignore: deprecated_member_use
      return await _fcm?.getToken();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> localTimezone() async {
    try {
      return (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {
      return 'UTC';
    }
  }
}

class NoNotifications implements NotificationService {
  final scheduled = <String>[];

  @override
  Future<void> init({required void Function(String link) onOpen}) async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> scheduleWorkoutReminders({
    required int hour,
    required List<int> weekdays,
  }) async => scheduled.add('workout@$hour:$weekdays');
  @override
  Future<void> scheduleCatchup(DateTime at) async =>
      scheduled.add('catchup@$at');
  @override
  Future<String?> fcmToken() async => null;
  @override
  Future<String> localTimezone() async => 'UTC';
}

/// UTC "weekday-hour" slot for the Sunday check-in push (server scheduler).
String checkinReminderSlot(int localHour, Duration utcOffset) {
  final local = DateTime.utc(2026, 1, 4, localHour); // a Sunday
  final utc = local.subtract(utcOffset);
  return '${utc.weekday % 7}-${utc.hour.toString().padLeft(2, '0')}';
}
