import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forme/core/errors.dart';
import 'package:forme/data/api/ai_api.dart';
import 'package:forme/data/demo.dart';
import 'package:forme/data/local/local_store.dart';
import 'package:forme/data/repo.dart';
import 'package:forme/data/sync/handlers.dart';
import 'package:forme/data/sync/outbox.dart';
import 'package:forme/data/sync/pull.dart';
import 'package:forme/data/sync/sync_engine.dart';
import 'package:forme/domain/models.dart';
import 'package:forme/domain/training.dart';
import 'package:forme/services/analytics.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers.dart';

class World {
  World(
    this.local,
    this.outbox,
    this.remote,
    this.api,
    this.analytics,
    this.online,
  );
  final LocalStore local;
  final Outbox outbox;
  final DemoRemote remote;
  final DemoAiApi api;
  final MemoryAnalytics analytics;
  bool online;
  late SyncEngine sync;
  late Repo repo;
  final now = DateTime(2026, 10, 19, 9);
}

Future<World> openWorld(
  String prefix, {
  DemoRemote? remote,
  DemoAiApi? api,
  bool pro = true,
}) async {
  final local = await LocalStore.open(prefix: prefix);
  final lib = loadLib();
  final w = World(
    local,
    Outbox(local.outboxBox),
    remote ?? DemoRemote(),
    api ?? DemoAiApi(lib, isPro: () => pro, latency: Duration.zero),
    MemoryAnalytics(),
    true,
  );
  final handlers = SyncHandlers(
    local: local,
    remote: w.remote,
    api: w.api,
    uid: () => 'u1',
  );
  w.sync = SyncEngine(
    outbox: w.outbox,
    handlers: handlers.map,
    isOnline: () async => w.online,
    rng: math.Random(1),
  );
  w.repo = Repo(
    local: local,
    outbox: w.outbox,
    sync: w.sync,
    api: w.api,
    lib: lib,
    analytics: w.analytics,
    uid: () => 'u1',
    now: () => w.now,
  );
  return w;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await initHive());
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('backoff', () {
    test('exponential with full jitter, capped', () {
      final r = math.Random(7);
      for (var n = 0; n < 30; n++) {
        final d = backoff(n, rng: r);
        expect(d.inMilliseconds, inInclusiveRange(250, 600000));
        if (n == 0) expect(d.inMilliseconds, lessThanOrEqualTo(2000));
      }
    });
  });

  group('outbox', () {
    test('enqueue is durable, FIFO, and dedupes by key', () async {
      final w = await openWorld('a');
      await w.outbox.enqueue('x', {'n': 1}, dedupeKey: 'k');
      await w.outbox.enqueue('y', {'n': 2});
      await w.outbox.enqueue('x', {'n': 3}, dedupeKey: 'k');
      expect(w.outbox.all().map((o) => o.payload['n']), [2, 3]);
      final op = w.outbox.all().first;
      await w.outbox.retryLater(op, const Duration(hours: 1), 'later');
      expect(w.outbox.due().map((o) => o.payload['n']), [3]);
      await w.outbox.fail(w.outbox.due().first, 'bad');
      expect(w.outbox.failed().single.error, 'bad');
      await w.outbox.requeueFailed();
      expect(w.outbox.failed(), isEmpty);
      expect(w.outbox.pendingCount, 2);
    });

    test('op json round-trip', () {
      final op = OutboxOp(
        id: 'i',
        kind: 'k',
        payload: const {
          'a': {
            'b': [1],
          },
        },
        createdAt: DateTime(2026),
        attempts: 2,
        nextAt: DateTime(2027),
        state: OpState.failed,
        error: 'e',
        seq: 4,
      );
      expect(OutboxOp.fromJson(op.toJson()).toJson(), op.toJson());
      expect(op.dueAt(DateTime(2028)), isFalse); // failed is never due
    });
  });

  group('sync engine', () {
    test('transient → retry later; permanent → failed and surfaced; unknown kind fails', () async {
      final w = await openWorld('b');
      var calls = 0;
      final failures = <String>[];
      final engine = SyncEngine(
        outbox: w.outbox,
        isOnline: () async => true,
        onPermanentFailure: (op, e) => failures.add(e),
        handlers: {
          't': (_) async {
            calls++;
            throw const TransientError('5xx');
          },
          'p': (_) async => throw const PermanentError('400'),
          'ok': (_) async {},
          'cap': (_) async => throw const CapReachedError(
            'meal',
            retryAfter: Duration(hours: 3),
            paywall: 'forme://paywall',
          ),
        },
      );
      await w.outbox.enqueue('t', {});
      await w.outbox.enqueue('p', {});
      await w.outbox.enqueue('ok', {});
      await w.outbox.enqueue('cap', {});
      await w.outbox.enqueue('nope', {});
      await engine.drain();
      expect(calls, 1);
      final all = w.outbox.all();
      expect(all.where((o) => o.kind == 'ok'), isEmpty);
      expect(all.firstWhere((o) => o.kind == 't').attempts, 1);
      expect(all.firstWhere((o) => o.kind == 'p').state, OpState.failed);
      expect(all.firstWhere((o) => o.kind == 'nope').state, OpState.failed);
      expect(
        all
            .firstWhere((o) => o.kind == 'cap')
            .nextAt!
            .difference(DateTime.now())
            .inMinutes,
        greaterThan(170),
      );
      expect(failures, hasLength(2));
      engine.dispose();
    });

    test('offline: nothing is attempted, nothing is lost', () async {
      final w = await openWorld('c');
      w.online = false;
      await w.outbox.enqueue(Ops.upsert, {
        'collection': 'workouts',
        'id': 'w1',
        'data': {'a': 1},
      });
      await w.sync.drain();
      expect(w.remote.docs, isEmpty);
      expect(w.outbox.pendingCount, 1);
      w.online = true;
      await w.sync.drain();
      expect(w.remote.docs['users/u1/workouts/w1'], {'a': 1});
      expect(w.outbox.all(), isEmpty);
    });

    test('concurrent drains are single-flight', () async {
      final w = await openWorld('d');
      var calls = 0;
      final engine = SyncEngine(
        outbox: w.outbox,
        isOnline: () async => true,
        handlers: {
          'x': (_) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          },
        },
      );
      await w.outbox.enqueue('x', {});
      await Future.wait([engine.drain(), engine.drain(), engine.drain()]);
      expect(calls, 1);
    });
  });

  test('EXIT BAR 3: airplane log → force-kill → relaunch → reconnect loses zero data', () async {
    // Session 1: offline, log a workout and a meal.
    var w = await openWorld('k');
    w.online = false;
    w.remote.offline = true;
    final p = plan(w.now);
    await w.local.savePlan(p);
    final session = sessionOn(p, w.now)!;
    final started = startWorkout(
      plan: p,
      session: session,
      week: 1,
      now: w.now,
      history: const [],
      lib: loadLib(),
    );
    await w.repo.saveWorkout(
      started.copyWith(
        sets: [for (final s in started.sets) s.copyWith(done: true, ts: w.now)],
      ),
    );
    await w.repo.finishWorkout(w.local.workout(started.id)!);
    await w.repo.logMeal(text: 'oats and banana');
    final queued = w.outbox.pendingCount;
    expect(queued, greaterThanOrEqualTo(3));

    // Force-kill: close every box without any further writes, then reopen.
    // (Let the offline no-op drain finish first; a real kill ends the process.)
    final remote = w.remote;
    await w.sync.drain();
    w.sync.dispose();
    await Hive.close();
    w = await openWorld('k', remote: remote);
    expect(w.local.workout(started.id)?.finished, isTrue);
    expect(w.local.meals.single.text, 'oats and banana');
    expect(w.outbox.pendingCount, queued);

    // Reconnect: everything reaches the server, nothing left behind.
    remote.offline = false;
    w.online = true;
    await w.sync.drain();
    expect(w.outbox.all(), isEmpty);
    expect(remote.docs.keys, contains('users/u1/workouts/${started.id}'));
    expect(
      remote.docs['users/u1/workouts/${started.id}']!['finished_at'],
      isNotNull,
    );
    expect(
      remote.docs.keys.where((k) => k.startsWith('users/u1/meals/')),
      hasLength(1),
    );
    expect(w.local.meals.single.status, MealStatus.done);
    expect(w.local.meals.single.ai, isNotNull);
  });

  group('repo + handlers', () {
    test(
      'meal over the free cap stays logged; AI job dropped, cap event fired',
      () async {
        final lib = loadLib();
        final api = DemoAiApi(lib, isPro: () => false, latency: Duration.zero);
        final w = await openWorld('m', api: api, pro: false);
        final caps = <String>[];
        final engine = SyncEngine(
          outbox: w.outbox,
          isOnline: () async => true,
          handlers: SyncHandlers(
            local: w.local,
            remote: w.remote,
            api: api,
            uid: () => 'u1',
            onCapReached: (e) => caps.add(e.cap),
          ).map,
        );
        for (var i = 0; i < 4; i++) {
          await w.outbox.enqueue(Ops.aiMeal, {
            'meal_id': (await w.local
                .saveMeal(
                  Meal(
                    id: 'm$i',
                    loggedAt: w.now,
                    text: 'meal $i',
                    status: MealStatus.analyzing,
                  ),
                )
                .then((_) => 'm$i')),
            'idem_key': 'meal-m$i',
          });
        }
        await engine.drain();
        expect(w.local.meal('m3')!.status, MealStatus.capReached);
        expect(w.local.meals.length, 4);
        expect(caps, ['meal']);
        expect(w.outbox.all(), isEmpty);
      },
    );

    test(
      'check-in: uploads, then AI report lands locally; free → manual',
      () async {
        final w = await openWorld('ck');
        final photos = [
          for (final a in ['front', 'side', 'back'])
            CheckinPhoto(angle: a, localPath: '/tmp/$a.jpg'),
        ];
        await w.repo.submitCheckin(
          Checkin(
            id: 'base',
            weekIndex: 0,
            createdAt: w.now,
            weightKg: 80,
            photos: photos,
            baseline: true,
          ),
          aiReport: false,
        );
        final sub = await w.repo.submitCheckin(
          Checkin(
            id: 'c1',
            weekIndex: 1,
            createdAt: w.now,
            weightKg: 79.4,
            photos: photos,
          ),
          aiReport: true,
        );
        expect(sub.status, CheckinStatus.uploading);
        expect(sub.photos.first.path, 'progress-photos/u1/c1/front.jpg');
        await w.sync.drain();
        final c = w.local.checkin('c1')!;
        expect(c.status, CheckinStatus.done);
        expect(c.report!.deltas.first.metric, 'weight_kg');
        expect(
          w.remote.uploads.keys,
          contains('progress-photos/u1/c1/back.jpg'),
        );
        expect(w.local.checkin('base')!.status, CheckinStatus.manual);
      },
    );

    test('createPlan falls back to the template when the AI is down', () async {
      final api = DemoAiApi(loadLib(), latency: Duration.zero)..offline = true;
      final w = await openWorld('pl', api: api);
      final p = await w.repo.createPlan(profile());
      expect(p.source, 'template');
      expect(p.queued, isTrue);
      expect(
        w.outbox.all().any((o) => o.payload['collection'] == 'plans'),
        isTrue,
      );
      api.offline = false;
      final p2 = await w.repo.createPlan(profile());
      expect(p2.source, 'ai');
    });

    test('replan (Pro) installs a new mesocycle at the next week', () async {
      final w = await openWorld('rp');
      await w.local.savePlan(plan(w.now));
      await w.repo.requestReplan(week: 2, survey: const Survey(sleep: 2));
      await w.sync.drain();
      final p = w.local.plan!;
      expect(p.version, 2);
      expect(p.weekOffset, 1);
      expect(p.cycle, 1);
    });

    test('coach chat stores both turns and maps the cap', () async {
      final api = DemoAiApi(loadLib(), latency: Duration.zero);
      final w = await openWorld('ch', api: api, pro: false);
      for (var i = 0; i < 5; i++) {
        await w.repo.chat('q$i', const {});
      }
      expect(w.local.chat.length, 10);
      await expectLater(
        w.repo.chat('one more', const {}),
        throwsA(isA<CapReachedError>()),
      );
      expect(w.local.chat.first.content, 'q0');
      expect(w.local.chat[1].role, 'assistant');
    });
  });

  group('pull (O3 last-write-wins)', () {
    test(
      'server-newer copy replaces local and is logged; pending local wins',
      () async {
        final w = await openWorld('pu');
        final p = plan(w.now);
        final mine = Workout(
          id: 'w1',
          planVersion: 1,
          week: 1,
          dayIndex: 0,
          sessionName: 'A',
          scheduledFor: w.now,
          updatedAt: w.now,
        );
        await w.local.saveWorkout(mine);
        w.remote.docs['users/u1/workouts/w1'] = {
          ...mine.copyWith(volumeKg: 999).toJson(),
          '_server_updated_at': w.now
              .add(const Duration(hours: 1))
              .toIso8601String(),
        };
        w.remote.docs['users/u1/workouts/w2'] = {
          ...Workout(
            id: 'w2',
            planVersion: 1,
            week: 1,
            dayIndex: 2,
            sessionName: 'B',
            scheduledFor: w.now,
          ).toJson(),
        };
        w.remote.docs['users/u1/checkins/c9'] = {
          'id': 'c9',
          'ai_report': const AiReport(
            summary: 'done',
            deltas: [],
            planChanges: [],
            coachNote: 'n',
            promptVersion: 'v1',
          ).toJson(),
        };
        await w.local.saveCheckin(
          Checkin(
            id: 'c9',
            weekIndex: 1,
            createdAt: w.now,
            status: CheckinStatus.queued,
          ),
        );
        final pull = SyncPull(
          local: w.local,
          remote: w.remote,
          outbox: w.outbox,
          analytics: w.analytics,
        );
        expect(await pull.run('u1'), 1);
        expect(w.local.workout('w1')!.volumeKg, 999);
        expect(w.local.workout('w2'), isNotNull);
        expect(w.local.checkin('c9')!.status, CheckinStatus.done);
        expect(w.analytics.logged(Events.syncConflict), isTrue);
        expect(p.version, 1);

        // A pending local edit is never overwritten by the pull.
        await w.repo.saveWorkout(w.local.workout('w1')!.copyWith(volumeKg: 5));
        w.online = false;
        await pull.run('u1');
        expect(w.local.workout('w1')!.volumeKg, 5);
        await w.sync.drain();
      },
    );
  });

  group('HTTP API error mapping', () {
    http.Response r(
      int code,
      Map<String, dynamic> body, [
      Map<String, String>? h,
    ]) => http.Response(jsonEncode(body), code, headers: h ?? const {});

    test('decode maps status codes to the taxonomy', () {
      expect(HttpAiApi.decode(r(200, {'a': 1})), {'a': 1});
      expect(
        () => HttpAiApi.decode(
          r(
            429,
            {
              'error': 'cap_reached',
              'cap': 'meal',
              'retry_after': 60,
              'paywall': 'forme://paywall?placement=cap_meal',
            },
            {'retry-after': '60'},
          ),
        ),
        throwsA(
          isA<CapReachedError>()
              .having((e) => e.cap, 'cap', 'meal')
              .having(
                (e) => e.retryAfter,
                'retry',
                const Duration(seconds: 60),
              ),
        ),
      );
      expect(
        () => HttpAiApi.decode(r(429, {'error': 'rate_limited'})),
        throwsA(isA<TransientError>()),
      );
      expect(
        () => HttpAiApi.decode(r(503, {})),
        throwsA(isA<TransientError>()),
      );
      expect(
        () => HttpAiApi.decode(r(409, {'error': 'in_progress'})),
        throwsA(isA<TransientError>()),
      );
      expect(
        () => HttpAiApi.decode(r(401, {})),
        throwsA(isA<TransientError>()),
      );
      expect(
        () => HttpAiApi.decode(r(400, {'error': 'expired'})),
        throwsA(isA<PermanentError>().having((e) => e.code, 'code', 'expired')),
      );
      expect(
        () => HttpAiApi.decode(http.Response('not json', 500)),
        throwsA(isA<TransientError>()),
      );
    });

    test('requests carry auth, idempotency and request ids', () async {
      late http.Request seen;
      final api = HttpAiApi(
        baseUrl: 'https://ai.test',
        idToken: () async => 'tok',
        client: MockClient((req) async {
          seen = req;
          return http.Response(
            jsonEncode({
              'name': 'Oats',
              'kcal': 300,
              'P': 10,
              'C': 50,
              'F': 5,
              'confidence': 0.8,
              'model': 'm',
            }),
            200,
          );
        }),
      );
      final m = await api.analyzeMeal(text: 'oats', idemKey: 'meal-abc12345');
      expect(m.kcal, 300);
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['Idempotency-Key'], 'meal-abc12345');
      expect(seen.headers['X-Request-Id'], isNotEmpty);
      expect(jsonDecode(seen.body), {'text': 'oats'});
    });

    test('signed-out and offline are surfaced', () async {
      final signedOut = HttpAiApi(
        baseUrl: 'https://ai.test',
        idToken: () async => null,
      );
      await expectLater(
        signedOut.redeemPromo('X-1234'),
        throwsA(isA<PermanentError>()),
      );
      final offline = HttpAiApi(
        baseUrl: 'https://ai.test',
        idToken: () async => 't',
        client: MockClient(
          (_) async => throw http.ClientException('no network'),
        ),
      );
      await expectLater(
        offline.redeemPromo('X-1234'),
        throwsA(isA<OfflineError>()),
      );
    });

    test('chat sends only the last 12 messages', () async {
      late Map<String, dynamic> body;
      final api = HttpAiApi(
        baseUrl: 'https://ai.test',
        idToken: () async => 't',
        client: MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'reply': 'ok',
              'suggestions': ['a'],
            }),
            200,
          );
        }),
      );
      final msgs = [
        for (var i = 0; i < 20; i++)
          ChatMessage(
            role: i.isEven ? 'user' : 'assistant',
            content: 'm$i',
            ts: DateTime(2026),
          ),
      ];
      final r = await api.chat(msgs, const {}, idemKey: 'chat-12345678');
      expect((body['messages'] as List).length, 12);
      expect(r.reply, 'ok');
    });
  });
}
