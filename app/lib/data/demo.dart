import 'dart:async';

import '../core/errors.dart';
import '../domain/exercise_library.dart';
import '../domain/models.dart';
import '../domain/plan_engine.dart';
import 'api/ai_api.dart';
import 'remote/remote.dart';

/// Offline demo backends (debug builds with DEMO_MODE=true, and tests).
/// They mimic the real service's behaviour, including free caps.
class DemoAiApi implements AiApi {
  DemoAiApi(
    this.lib, {
    this.isPro = _never,
    this.latency = const Duration(milliseconds: 600),
  });

  final ExerciseLibrary lib;
  final bool Function() isPro;
  final Duration latency;
  final calls = <String>[];
  int _meals = 0;
  int _chats = 0;
  bool offline = false;

  static bool _never() => false;

  Future<void> _wait(String name) async {
    calls.add(name);
    await Future<void>.delayed(latency);
    if (offline) throw const OfflineError();
  }

  @override
  Future<PlanResult> generatePlan(
    Profile profile, {
    required String idemKey,
  }) async {
    await _wait('plan');
    return PlanResult(
      version: 1,
      mesocycle: PlanEngine(lib).template(profile),
      source: 'ai',
      queued: false,
    );
  }

  @override
  Future<PlanResult> regeneratePlan({
    required String uid,
    required int week,
    required int planned,
    required int completed,
    Survey? survey,
    Mesocycle? current,
    required String idemKey,
  }) async {
    await _wait('replan');
    if (!isPro()) {
      throw const CapReachedError(
        'plan_regen',
        retryAfter: Duration(days: 30),
        paywall: 'forme://paywall?placement=cap_plan_regen',
      );
    }
    return PlanResult(
      version: 2,
      mesocycle: current!,
      source: 'ai',
      queued: false,
    );
  }

  @override
  Future<CheckinResult> analyzeCheckin(
    Map<String, dynamic> body, {
    required String idemKey,
  }) async {
    await _wait('checkin');
    if (!isPro()) {
      throw const CapReachedError(
        'photo',
        retryAfter: Duration(days: 30),
        paywall: 'forme://paywall?placement=cap_photo',
      );
    }
    final weeks = (body['week_index'] as int).clamp(1, 52);
    final hist = (body['history'] as List).cast<Map<String, dynamic>>();
    final prevW = hist.isEmpty
        ? null
        : (hist.last['weight_kg'] as num?)?.toDouble();
    final w = (body['weight_kg'] as num?)?.toDouble();
    return CheckinResult(
      report: AiReport(
        summary:
            'Steady week. Your midsection looks tighter in the side view and your weight '
            'trend is moving the right way.',
        deltas: [
          if (prevW != null && w != null)
            Delta(
              metric: 'weight_kg',
              from: prevW,
              to: w,
              unit: 'kg',
              confidence: 0.95,
            ),
          Delta(
            metric: 'waist_cm',
            from: 86,
            to: 86 - 0.8 * weeks,
            unit: 'cm',
            confidence: 0.6,
          ),
          Delta(
            metric: 'body_fat_pct',
            from: 22,
            to: 22 - 0.35 * weeks,
            unit: '%',
            confidence: 0.5,
          ),
        ],
        planChanges: const ['+2.5 kg on lower-body lifts', 'Protein → 140 g'],
        coachNote: 'Consistency is showing — keep stacking weeks like this.',
        promptVersion: 'v1',
      ),
      queued: false,
      morphReady: hist.isNotEmpty,
    );
  }

  @override
  Future<Macros> analyzeMeal({
    String? photoB64,
    String? text,
    required String idemKey,
  }) async {
    await _wait('meal');
    if (!isPro() && _meals >= 3) {
      throw const CapReachedError(
        'meal',
        retryAfter: Duration(hours: 8),
        paywall: 'forme://paywall?placement=cap_meal',
      );
    }
    _meals++;
    final kcal = 420 + (text?.length ?? 7) * 7 % 380;
    return Macros(
      kcal: kcal,
      p: kcal * 0.3 / 4,
      c: kcal * 0.45 / 4,
      f: kcal * 0.25 / 9,
      confidence: 0.82,
      model: 'demo',
      name: text?.isNotEmpty == true ? text! : 'Chicken rice bowl',
    );
  }

  @override
  Future<CoachReply> chat(
    List<ChatMessage> messages,
    Map<String, dynamic> capsule, {
    required String idemKey,
  }) async {
    await _wait('chat');
    final limit = isPro() ? 20 : 5;
    if (_chats >= limit) {
      throw const CapReachedError(
        'chat',
        retryAfter: Duration(days: 30),
        paywall: 'forme://paywall?placement=cap_chat',
      );
    }
    _chats++;
    return const CoachReply(
      reply:
          'Nice work showing up this week. Keep the next session short and focused — '
          'quality reps beat volume when sleep is low.',
      suggestions: ['Swap an exercise', '20-min catch-up?', 'Protein ideas'],
      flagged: false,
    );
  }

  @override
  Future<String> renderPreview({
    required String photoPath,
    required String goal,
    required String idemKey,
  }) async {
    await _wait('preview');
    if (!isPro()) {
      throw const CapReachedError(
        'render',
        retryAfter: Duration(days: 30),
        paywall: 'forme://paywall?placement=cap_render',
      );
    }
    return 'previews/_placeholder/v1.jpg';
  }

  @override
  Future<DateTime> redeemPromo(String code) async {
    await _wait('promo');
    if (code != 'FORME-TEAM')
      throw const PermanentError('not_found', code: 'not_found');
    return DateTime.now().add(const Duration(days: 30));
  }
}

class DemoRemote implements Remote {
  final docs = <String, Map<String, dynamic>>{};
  final uploads = <String, String>{};
  final _user = StreamController<Map<String, dynamic>?>.broadcast();
  bool offline = false;

  void _check() {
    if (offline) throw const OfflineError();
  }

  @override
  Future<void> upsert(
    String uid,
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    _check();
    final key = collection.isEmpty
        ? 'users/$uid'
        : 'users/$uid/$collection/$id';
    docs[key] = {...?docs[key], ...data};
    if (collection.isEmpty) _user.add(docs[key]);
  }

  @override
  Future<void> upload(String localPath, String storagePath) async {
    _check();
    uploads[storagePath] = localPath;
  }

  @override
  Future<List<Map<String, dynamic>>> recent(
    String uid,
    String collection, {
    required String orderBy,
    int limit = 50,
  }) async {
    _check();
    return docs.entries
        .where((e) => e.key.startsWith('users/$uid/$collection/'))
        .map((e) => e.value)
        .take(limit)
        .toList();
  }

  @override
  Stream<Map<String, dynamic>?> userDoc(String uid) => _user.stream;

  @override
  Future<void> deleteAccount() async {
    _check();
    docs.clear();
    uploads.clear();
  }
}
