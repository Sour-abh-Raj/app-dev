import '../../domain/models.dart';
import '../../services/analytics.dart';
import '../local/local_store.dart';
import '../remote/remote.dart';
import 'outbox.dart';

/// Pull-on-start merge (O3). Last write wins on the *server* timestamp; a
/// local copy with an unsent outbox op is newer by definition and is kept.
/// Every overwrite of a differing local copy is logged as a conflict.
class SyncPull {
  SyncPull({
    required this.local,
    required this.remote,
    required this.outbox,
    required this.analytics,
  });

  final LocalStore local;
  final Remote remote;
  final Outbox outbox;
  final Analytics analytics;

  Set<String> _pendingIds() => {
    for (final op in outbox.all())
      if (op.payload['id'] is String)
        '${op.payload['collection']}/${op.payload['id']}',
    for (final op in outbox.all())
      if (op.payload['checkin_id'] is String)
        'checkins/${op.payload['checkin_id']}',
  };

  Future<int> run(String uid) async {
    final pending = _pendingIds();
    var conflicts = 0;

    for (final doc in await remote.recent(
      uid,
      'workouts',
      orderBy: 'scheduled_for',
      limit: 60,
    )) {
      final remoteW = _workout(doc);
      if (remoteW == null || pending.contains('workouts/${remoteW.id}')) {
        continue;
      }
      final mine = local.workout(remoteW.id);
      if (mine == null) {
        await local.saveWorkout(remoteW);
      } else if (_newer(doc, mine.updatedAt) &&
          mine.toJson().toString() != remoteW.toJson().toString()) {
        conflicts++;
        await local.saveWorkout(remoteW);
      }
    }

    for (final doc in await remote.recent(
      uid,
      'checkins',
      orderBy: 'week_index',
      limit: 30,
    )) {
      final id = doc['id'] as String? ?? doc['_id'] as String?;
      if (id == null || pending.contains('checkins/$id')) continue;
      final mine = local.checkin(id);
      final report = doc['ai_report'];
      if (mine != null && mine.report == null && report is Map) {
        // The server finished a queued analysis while we were away.
        await local.saveCheckin(
          mine.copyWith(
            report: AiReport.fromJson(report),
            status: CheckinStatus.done,
          ),
        );
      }
    }

    if (conflicts > 0) {
      await analytics.log(Events.syncConflict, {'count': conflicts});
    }
    return conflicts;
  }

  static bool _newer(Map<String, dynamic> doc, DateTime? localUpdated) {
    final s = doc['_server_updated_at'] as String?;
    if (s == null || localUpdated == null) return false;
    return DateTime.parse(s).isAfter(localUpdated);
  }

  static Workout? _workout(Map<String, dynamic> doc) {
    try {
      return Workout.fromJson({
        ...doc,
        for (final k in [
          'scheduled_for',
          'started_at',
          'finished_at',
          'updated_at',
        ])
          k: _iso(doc[k]),
      });
    } catch (_) {
      return null;
    }
  }

  static String? _iso(Object? v) {
    if (v == null) return null;
    if (v is String) return v;
    try {
      return ((v as dynamic).toDate() as DateTime).toIso8601String();
    } catch (_) {
      return null;
    }
  }
}
