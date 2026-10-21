import 'dart:async';

import 'package:hive/hive.dart';

import '../../domain/access.dart';
import '../../domain/models.dart';

/// Hive is the offline source of truth (O1). Values are stored as JSON maps
/// so no adapters or code generation are needed.
class LocalStore {
  LocalStore._(
    this._kv,
    this._workouts,
    this._meals,
    this._checkins,
    this._chat,
    this._outbox,
  );

  final Box<dynamic> _kv;
  final Box<dynamic> _workouts;
  final Box<dynamic> _meals;
  final Box<dynamic> _checkins;
  final Box<dynamic> _chat;
  final Box<dynamic> _outbox;

  static const boxes = [
    'kv',
    'workouts',
    'meals',
    'checkins',
    'chat',
    'outbox',
  ];

  /// Opens all boxes. [prefix] isolates test runs.
  static Future<LocalStore> open({String prefix = ''}) async {
    final b = <Box<dynamic>>[];
    for (final name in boxes) {
      b.add(await Hive.openBox<dynamic>('$prefix$name'));
    }
    return LocalStore._(b[0], b[1], b[2], b[3], b[4], b[5]);
  }

  Box<dynamic> get outboxBox => _outbox;

  final _changes = StreamController<String>.broadcast();
  int _seq = 0;

  /// Emits `box#seq` after every local write so providers can refresh.
  /// The sequence keeps consecutive writes to one box distinct (Riverpod skips
  /// notifying listeners when a stream repeats an equal value).
  Stream<String> get changes => _changes.stream;

  void _changed(String box) => _changes.add('$box#${_seq++}');

  Future<void> _put(Box<dynamic> box, String key, Object? value) async {
    await box.put(key, value);
    await box.flush(); // durable before the UI acknowledges (force-kill safe)
    _changed(box.name);
  }

  // ---------- key/value ----------

  Profile? get profile {
    final j = _kv.get('profile');
    return j == null ? null : Profile.fromJson(j as Map);
  }

  Future<void> saveProfile(Profile p) => _put(_kv, 'profile', p.toJson());

  Plan? get plan {
    final j = _kv.get('plan');
    return j == null ? null : Plan.fromJson(j as Map);
  }

  Future<void> savePlan(Plan p) => _put(_kv, 'plan', p.toJson());

  Entitlement get entitlement {
    final j = _kv.get('entitlement');
    return j == null ? const Entitlement() : Entitlement.fromJson(j as Map);
  }

  Future<void> saveEntitlement(Entitlement e) =>
      _put(_kv, 'entitlement', e.toJson());

  bool get onboarded => _kv.get('onboarded', defaultValue: false) as bool;
  Future<void> setOnboarded(bool v) => _put(_kv, 'onboarded', v);

  T? read<T>(String key) => _kv.get(key) as T?;
  Future<void> write(String key, Object? value) => _put(_kv, key, value);

  // ---------- collections ----------

  List<Workout> get workouts =>
      _workouts.values.map((j) => Workout.fromJson(j as Map)).toList()
        ..sort((a, b) => b.scheduledFor.compareTo(a.scheduledFor));

  Workout? workout(String id) {
    final j = _workouts.get(id);
    return j == null ? null : Workout.fromJson(j as Map);
  }

  Future<void> saveWorkout(Workout w) => _put(_workouts, w.id, w.toJson());

  List<Meal> get meals =>
      _meals.values.map((j) => Meal.fromJson(j as Map)).toList()
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));

  Meal? meal(String id) {
    final j = _meals.get(id);
    return j == null ? null : Meal.fromJson(j as Map);
  }

  Future<void> saveMeal(Meal m) => _put(_meals, m.id, m.toJson());
  Future<void> deleteMeal(String id) async {
    await _meals.delete(id);
    _changed(_meals.name);
  }

  List<Checkin> get checkins =>
      _checkins.values.map((j) => Checkin.fromJson(j as Map)).toList()
        ..sort((a, b) => a.weekIndex.compareTo(b.weekIndex));

  Checkin? checkin(String id) {
    final j = _checkins.get(id);
    return j == null ? null : Checkin.fromJson(j as Map);
  }

  Future<void> saveCheckin(Checkin c) => _put(_checkins, c.id, c.toJson());

  /// Hive iterates keys in sorted order; zero-padded sequence keys keep the
  /// conversation in insertion order even when timestamps tie.
  List<ChatMessage> get chat =>
      _chat.values.map((j) => ChatMessage.fromJson(j as Map)).toList();

  Future<void> addChat(ChatMessage m) =>
      _put(_chat, _chat.length.toString().padLeft(9, '0'), m.toJson());

  /// Local wipe after account deletion or sign-out.
  Future<void> clearAll() async {
    for (final b in [_kv, _workouts, _meals, _checkins, _chat, _outbox]) {
      await b.clear();
    }
    _changed('all');
  }
}
