import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../core/errors.dart';
import '../../domain/models.dart';

/// Client for the FastAPI AI service. Every call carries the Firebase ID token,
/// an idempotency key (O7) and a request id; errors map to the app taxonomy.
abstract class AiApi {
  Future<PlanResult> generatePlan(Profile profile, {required String idemKey});
  Future<PlanResult> regeneratePlan({
    required String uid,
    required int week,
    required int planned,
    required int completed,
    Survey? survey,
    Mesocycle? current,
    required String idemKey,
  });
  Future<CheckinResult> analyzeCheckin(
    Map<String, dynamic> body, {
    required String idemKey,
  });
  Future<Macros> analyzeMeal({
    String? photoB64,
    String? text,
    required String idemKey,
  });
  Future<CoachReply> chat(
    List<ChatMessage> messages,
    Map<String, dynamic> capsule, {
    required String idemKey,
  });
  Future<String> renderPreview({
    required String photoPath,
    required String goal,
    required String idemKey,
  });
  Future<DateTime> redeemPromo(String code);
}

class PlanResult {
  const PlanResult({
    required this.version,
    required this.mesocycle,
    required this.source,
    required this.queued,
  });
  final int version;
  final Mesocycle mesocycle;
  final String source;
  final bool queued;
}

class CheckinResult {
  const CheckinResult({
    required this.report,
    required this.queued,
    required this.morphReady,
  });
  final AiReport? report;
  final bool queued;
  final bool morphReady;
}

class CoachReply {
  const CoachReply({
    required this.reply,
    required this.suggestions,
    required this.flagged,
  });
  final String reply;
  final List<String> suggestions;
  final bool flagged;
}

class HttpAiApi implements AiApi {
  HttpAiApi({
    required this.baseUrl,
    required this.idToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 60),
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final Future<String?> Function() idToken;
  final Duration timeout;
  final http.Client _http;
  static const _uuid = Uuid();

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? idemKey,
  }) async {
    final token = await idToken();
    if (token == null) {
      throw const PermanentError('not signed in', code: 'unauthenticated');
    }
    final http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'X-Request-Id': _uuid.v4(),
              'Idempotency-Key': ?idemKey,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on SocketException {
      throw const OfflineError();
    } on TimeoutException {
      throw const TransientError('timed out');
    } on http.ClientException {
      throw const OfflineError();
    }
    return decode(res);
  }

  /// Maps an HTTP response onto success or the error taxonomy. Public for tests.
  static Map<String, dynamic> decode(http.Response res) {
    Map<String, dynamic> body;
    try {
      body = res.body.isEmpty
          ? {}
          : jsonDecode(res.body) as Map<String, dynamic>;
    } on FormatException {
      body = {};
    }
    final code = res.statusCode;
    if (code >= 200 && code < 300) return body;
    final retryAfter = Duration(
      seconds:
          int.tryParse(res.headers['retry-after'] ?? '') ??
          (body['retry_after'] as num?)?.toInt() ??
          30,
    );
    final err = body['error'] as String? ?? 'http_$code';
    if (code == 429 && err == 'cap_reached') {
      throw CapReachedError(
        body['cap'] as String? ?? 'ai',
        retryAfter: retryAfter,
        paywall: body['paywall'] as String? ?? 'forme://paywall',
      );
    }
    if (code == 429 || code == 409 || code == 408 || code >= 500) {
      throw TransientError(err, retryAfter: retryAfter);
    }
    if (code == 401) throw TransientError(err); // token refresh, then retry
    throw PermanentError(err, code: err);
  }

  PlanResult _plan(Map<String, dynamic> j) => PlanResult(
    version: j['version'] as int,
    mesocycle: Mesocycle.fromJson(j['mesocycle'] as Map),
    source: j['source'] as String,
    queued: j['queued'] as bool? ?? false,
  );

  @override
  Future<PlanResult> generatePlan(
    Profile profile, {
    required String idemKey,
  }) async => _plan(
    await _post('/v1/plan/generate', {
      'onboarding': profile.toOnboarding(),
    }, idemKey: idemKey),
  );

  @override
  Future<PlanResult> regeneratePlan({
    required String uid,
    required int week,
    required int planned,
    required int completed,
    Survey? survey,
    Mesocycle? current,
    required String idemKey,
  }) async => _plan(
    await _post('/v1/plan/regenerate', {
      'uid': uid,
      'week': week,
      'adherence': {
        'planned_sessions': planned,
        'completed_sessions': completed,
      },
      'survey': ?survey?.toJson(),
      'current': ?current?.toJson(),
    }, idemKey: idemKey),
  );

  @override
  Future<CheckinResult> analyzeCheckin(
    Map<String, dynamic> body, {
    required String idemKey,
  }) async {
    final j = await _post('/v1/checkin/analyze', body, idemKey: idemKey);
    return CheckinResult(
      report: j['ai_report'] == null
          ? null
          : AiReport.fromJson(j['ai_report'] as Map),
      queued: j['status'] == 'queued',
      morphReady: j['morph_ready'] as bool? ?? false,
    );
  }

  @override
  Future<Macros> analyzeMeal({
    String? photoB64,
    String? text,
    required String idemKey,
  }) async {
    final j = await _post('/v1/meal/analyze', {
      'photo_b64': ?photoB64,
      'text': ?text,
    }, idemKey: idemKey);
    return Macros.fromJson(j);
  }

  @override
  Future<CoachReply> chat(
    List<ChatMessage> messages,
    Map<String, dynamic> capsule, {
    required String idemKey,
  }) async {
    final recent = messages.where((m) => !m.flagged).toList();
    final j = await _post('/v1/coach/chat', {
      'messages': [
        for (final m in recent.skip(
          recent.length > 12 ? recent.length - 12 : 0,
        ))
          {'role': m.role, 'content': m.content},
      ],
      'capsule': capsule,
    }, idemKey: idemKey);
    return CoachReply(
      reply: j['reply'] as String,
      suggestions: List<String>.from(j['suggestions'] as List? ?? const []),
      flagged: j['flagged'] as bool? ?? false,
    );
  }

  @override
  Future<String> renderPreview({
    required String photoPath,
    required String goal,
    required String idemKey,
  }) async {
    final j = await _post('/v1/preview/render', {
      'photo': photoPath,
      'goal': goal,
    }, idemKey: idemKey);
    return j['result_path'] as String;
  }

  @override
  Future<DateTime> redeemPromo(String code) async {
    final j = await _post('/v1/promo/redeem', {'code': code});
    return DateTime.parse(j['expires_at'] as String);
  }
}
