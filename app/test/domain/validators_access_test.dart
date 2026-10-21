import 'package:flutter_test/flutter_test.dart';
import 'package:forme/core/clock.dart';
import 'package:forme/domain/access.dart';
import 'package:forme/domain/models.dart';
import 'package:forme/domain/pose_logic.dart';
import 'package:forme/domain/validators.dart';

void main() {
  group('validators', () {
    test('weight/height/birth year', () {
      expect(Validators.weightKg(null), isNotNull);
      expect(Validators.weightKg(29), isNotNull);
      expect(Validators.weightKg(80), isNull);
      expect(Validators.heightCm(null), isNull);
      expect(Validators.heightCm(99), isNotNull);
      expect(Validators.heightCm(180), isNull);
      final now = DateTime(2026, 10, 21);
      expect(Validators.birthYear(2010, now), contains('18+'));
      expect(Validators.birthYear(1900, now), isNotNull);
      expect(Validators.birthYear(1990, now), isNull);
      expect(Validators.birthYear(null, now), isNull);
    });

    test('reps/load', () {
      expect(Validators.reps(-1), isNotNull);
      expect(Validators.reps(301), isNotNull);
      expect(Validators.reps(12), isNull);
      expect(Validators.loadKg(-1), isNotNull);
      expect(Validators.loadKg(401), isNotNull);
      expect(Validators.loadKg(60), isNull);
    });

    test('macros must add up', () {
      expect(Validators.macros(kcal: 500, p: 30, c: 50, f: 20), isNull); // 500
      expect(Validators.macros(kcal: 900, p: 30, c: 50, f: 20), isNotNull);
      expect(Validators.macros(kcal: -1, p: 0, c: 0, f: 0), isNotNull);
      expect(Validators.macros(kcal: 6000, p: 0, c: 0, f: 0), isNotNull);
      expect(
        Validators.macros(kcal: 40, p: 0, c: 0, f: 0),
        isNull,
      ); // within ±60 kcal
    });

    test('promo normalisation matches the server', () {
      expect(Validators.normalizePromo(' forme-team 01 '), 'FORME-TEAM01');
      expect(Validators.normalizePromo('bad\$'), isNull);
      expect(Validators.normalizePromo('ab'), isNull);
    });

    test('text inputs', () {
      expect(Validators.mealText(''), isNotNull);
      expect(Validators.mealText('x' * 501), isNotNull);
      expect(Validators.mealText('eggs'), isNull);
      expect(Validators.email('a@b.co'), isNull);
      expect(Validators.email('nope'), isNotNull);
      expect(Validators.password('short'), isNotNull);
      expect(Validators.password('long enough'), isNull);
      expect(Validators.chatMessage(''), '');
      expect(Validators.chatMessage('x' * 2001), isNotNull);
      expect(Validators.chatMessage('hi'), isNull);
    });
  });

  group('access', () {
    final now = DateTime(2026, 10, 21, 12);

    test('tiers: pro, free, grace', () {
      expect(const Entitlement().tierAt(now), Tier.free);
      expect(Entitlement(pro: true, fetchedAt: now).tierAt(now), Tier.pro);
      expect(const Entitlement(everSubscribed: true).tierAt(now), Tier.grace);
    });

    test('cached pro survives ≤7 days offline, not longer', () {
      final e = Entitlement(
        pro: true,
        everSubscribed: true,
        fetchedAt: now.subtract(const Duration(days: 6)),
      );
      expect(e.tierAt(now), Tier.pro);
      expect(e.tierAt(now.add(const Duration(days: 2))), Tier.grace);
    });

    test('winback eligibility', () {
      final e = Entitlement(
        everSubscribed: true,
        winbackUntil: now.add(const Duration(days: 3)),
      );
      expect(e.winbackEligible(now), isTrue);
      expect(e.winbackEligible(now.add(const Duration(days: 4))), isFalse);
      expect(
        Entitlement(
          pro: true,
          fetchedAt: now,
          winbackUntil: now.add(const Duration(days: 3)),
        ).winbackEligible(now),
        isFalse,
      );
    });

    test('feature gates: grace == free allowances, data never locked', () {
      for (final t in [Tier.free, Tier.grace]) {
        final a = Access(t);
        expect(
          a.workoutLogger && a.photoCapture && a.prGraphs && a.manualSideBySide,
          isTrue,
        );
        expect(
          a.aiPhotoReports || a.timelineAndMorph || a.adaptiveReplans,
          isFalse,
        );
        expect(
          (a.aiMealsPerDay, a.chatAllowance, a.chatAllowanceIsMonthly),
          (3, 5, false),
        );
      }
      const pro = Access(Tier.pro);
      expect(
        pro.aiPhotoReports && pro.timelineAndMorph && pro.futureRender,
        isTrue,
      );
      expect((pro.chatAllowance, pro.chatAllowanceIsMonthly), (20, true));
    });

    test('entitlement json round-trip', () {
      final e = Entitlement(
        pro: true,
        trial: true,
        expiresAt: now,
        productId: 'annual',
        billingIssue: true,
        willRenew: true,
        everSubscribed: true,
        winbackUntil: now,
        promo: true,
        fetchedAt: now,
      );
      final r = Entitlement.fromJson(e.toJson());
      expect(r.toJson(), e.toJson());
    });
  });

  group('pose hints', () {
    Landmarks body({
      double cx = 0.5,
      double top = 0.1,
      double bottom = 0.9,
      double sw = 0.2,
      double tilt = 0,
    }) {
      return {
        'nose': Offset(cx, top),
        'l_eye': Offset(cx - 0.02, top - 0.01),
        'r_eye': Offset(cx + 0.02, top - 0.01),
        'l_shoulder': Offset(cx + sw / 2, top + 0.12 + tilt),
        'r_shoulder': Offset(cx - sw / 2, top + 0.12),
        'l_hip': Offset(cx + 0.06, top + 0.4),
        'r_hip': Offset(cx - 0.06, top + 0.4),
        'l_ankle': Offset(cx + 0.05, bottom),
        'r_ankle': Offset(cx - 0.05, bottom),
      };
    }

    test('ready when framed', () {
      expect(PoseHints.evaluate(body(), 'front').ready, isTrue);
      expect(PoseHints.evaluate(body(sw: 0.05), 'side').ready, isTrue);
    });

    test('guidance messages', () {
      expect(PoseHints.evaluate(null, 'front').message, contains('Step into'));
      expect(
        PoseHints.evaluate(body(top: 0.01), 'front').message,
        contains('Step back'),
      );
      expect(
        PoseHints.evaluate(body(top: 0.3, bottom: 0.7), 'front').message,
        contains('closer'),
      );
      expect(
        PoseHints.evaluate(body(cx: 0.2), 'front').message,
        contains('right'),
      );
      expect(
        PoseHints.evaluate(body(cx: 0.8), 'front').message,
        contains('left'),
      );
      expect(PoseHints.evaluate(body(), 'side').message, contains('side'));
      expect(
        PoseHints.evaluate(body(sw: 0.05), 'front').message,
        contains('square'),
      );
      expect(
        PoseHints.evaluate(body(sw: 0.05), 'back').message,
        contains('Face away'),
      );
      expect(
        PoseHints.evaluate(body(tilt: 0.08), 'front').message,
        contains('level'),
      );
    });

    test('face rect covers the head', () {
      final r = PoseHints.faceRect(body())!;
      expect(r.contains(const Offset(0.5, 0.1)), isTrue);
      expect(PoseHints.faceRect({'nose': const Offset(0.5, 0.1)}), isNull);
    });

    test('alignment maps current torso onto baseline', () {
      final base = Alignment2D.torso(body())!;
      final cur = Alignment2D.torso(body(top: 0.2, bottom: 0.95))!;
      final a = Alignment2D.between(base, cur);
      expect(a.scale, closeTo(1, 1e-9));
      expect(cur['sy']! * a.scale + a.dy, closeTo(base['sy']!, 1e-9));
      expect(Alignment2D.between(null, cur).scale, 1);
      expect(
        Alignment2D.between({'sx': 0, 'sy': 0, 'hx': 0, 'hy': 0}, cur).scale,
        1,
      );
      expect(Alignment2D.torso(null), isNull);
      expect(Alignment2D.torso({'nose': Offset.zero}), isNull);
    });
  });

  group('models', () {
    test('delta display carries confidence wording', () {
      const d = Delta(
        metric: 'waist_cm',
        from: 86,
        to: 82.8,
        unit: 'cm',
        confidence: 0.6,
      );
      expect(d.display, '−3.2 cm (est.)');
      expect(d.label, 'Waist');
      const w = Delta(
        metric: 'weight_kg',
        from: 80,
        to: 80.5,
        unit: 'kg',
        confidence: 0.95,
      );
      expect(w.display, '+0.5 kg');
      const z = Delta(metric: 'x', from: 1, to: 1, unit: '', confidence: 0.1);
      expect(z.display.startsWith('±'), isTrue);
      expect(z.label, 'x');
    });

    test('json round-trips', () {
      final now = DateTime(2026, 10, 21);
      final prof = Profile(
        name: 'A',
        birthYear: 1990,
        sex: 'female',
        heightCm: 165,
        weightKg: 60,
        goal: Goal.recomp,
        targetKg: 58,
        injuries: ['knee'],
        createdAt: now,
        adultConsent: true,
      );
      expect(Profile.fromJson(prof.toJson()).toJson(), prof.toJson());
      expect(prof.toOnboarding()['goal'], 'recomp');
      expect(
        profileFromFirestore({
          ...prof.toFirestore(),
          'goal': {'type': 'recomp'},
        })!.goal,
        Goal.recomp,
      );
      expect(profileFromFirestore(null), isNull);

      final meal = Meal(
        id: 'm',
        loggedAt: now,
        text: 'eggs',
        ai: const Macros(
          kcal: 300,
          p: 20,
          c: 10,
          f: 15,
          confidence: 0.8,
          model: 'x',
          name: 'Eggs',
        ),
        status: MealStatus.needsConnection,
        idemKey: 'k',
      );
      expect(Meal.fromJson(meal.toJson()).toJson(), meal.toJson());
      expect(meal.macros?.kcal, 300);

      final c = Checkin(
        id: 'c',
        weekIndex: 2,
        createdAt: now,
        weightKg: 80,
        photos: const [
          CheckinPhoto(
            angle: 'front',
            localPath: '/x.jpg',
            path: 'progress-photos/u/c/front.jpg',
            landmarks: {'sx': 0.5},
          ),
        ],
        survey: const Survey(adherence: 4),
        report: const AiReport(
          summary: 's',
          deltas: [],
          planChanges: ['a'],
          coachNote: 'n',
          promptVersion: 'v1',
        ),
        status: CheckinStatus.done,
      );
      expect(Checkin.fromJson(c.toJson()).toJson(), c.toJson());
      expect(c.photos.first.thumb, 'progress-photos/u/c/front_thumb.jpg');
      expect(c.photo('side'), isNull);

      final chat = ChatMessage(
        role: 'user',
        content: 'hi',
        ts: now,
        flagged: true,
      );
      expect(ChatMessage.fromJson(chat.toJson()).toJson(), chat.toJson());
      expect(dateOnly(DateTime(2026, 1, 2, 13)), DateTime(2026, 1, 2));
    });
  });
}
