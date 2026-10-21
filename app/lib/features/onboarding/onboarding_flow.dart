import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../domain/models.dart';
import '../../domain/validators.dart';
import '../../services/analytics.dart';
import '../../services/auth_service.dart';
import '../../widgets/common.dart';
import '../checkin/capture.dart';

/// O1 → O7: welcome, goal, level/equipment/schedule, injuries, baseline photos
/// (before the paywall), auth, plan generation → D7 paywall → T1.
class OnboardingFlow extends ConsumerStatefulWidget {
  const OnboardingFlow({super.key});

  @override
  ConsumerState<OnboardingFlow> createState() => _OnboardingFlowState();
}

enum _Step {
  welcome,
  goal,
  setup,
  injuries,
  photosIntro,
  photos,
  auth,
  generating,
}

class _OnboardingFlowState extends ConsumerState<OnboardingFlow> {
  _Step _step = _Step.welcome;
  Profile _p = Profile();
  List<CheckinPhoto> _baseline = const [];
  final _checkinId = 'w0-${const Uuid().v4().substring(0, 8)}';
  bool _returning = false;

  void _go(_Step s) => setState(() => _step = s);

  /// Returning user on a new device: restore profile + latest plan from the server.
  Future<bool> _restore() async {
    final s = ref.read(servicesProvider);
    final uid = s.auth.current?.uid;
    if (uid == null) return false;
    try {
      final doc = await s.remote
          .userDoc(uid)
          .first
          .timeout(const Duration(seconds: 10));
      final profile = profileFromFirestore(doc);
      if (profile == null) return false;
      final plans = await s.remote.recent(
        uid,
        'plans',
        orderBy: 'version',
        limit: 1,
      );
      await s.local.saveProfile(profile);
      final now = ref.read(clockProvider).now();
      if (plans.isNotEmpty && plans.first['mesocycle_json'] is Map) {
        await s.local.savePlan(
          Plan(
            version: plans.first['version'] as int? ?? 1,
            startDate: profile.createdAt ?? now,
            mesocycle: Mesocycle.fromJson(plans.first['mesocycle_json'] as Map),
            source: plans.first['source'] as String? ?? 'ai',
          ),
        );
      } else {
        await ref.read(repoProvider).createPlan(profile);
      }
      await s.local.setOnboarded(true);
      if (mounted) context.go('/today');
      return true;
    } catch (_) {
      return false;
    }
  }

  void _back() {
    if (_step.index > 0) _go(_Step.values[_step.index - 1]);
  }

  @override
  Widget build(BuildContext context) {
    final total = _Step.values.length - 1;
    return PopScope(
      canPop: _step == _Step.welcome,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step != _Step.generating) _back();
      },
      child: Scaffold(
        appBar: _step == _Step.welcome || _step == _Step.generating
            ? null
            : AppBar(
                leading: BackButton(onPressed: _back),
                title: ProgressBar(_step.index / total, height: 6),
              ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(key: ValueKey(_step), child: _body()),
          ),
        ),
      ),
    );
  }

  Widget _body() => switch (_step) {
    _Step.welcome => _Welcome(
      onStart: () => _go(_Step.goal),
      onSignIn: () {
        _returning = true;
        _go(_Step.auth);
      },
    ),
    _Step.goal => _GoalStep(
      selected: _p.goal,
      onPick: (g) {
        setState(() => _p = _p.copyWith(goal: g));
        _go(_Step.setup);
      },
    ),
    _Step.setup => _SetupStep(
      profile: _p,
      onChanged: (p) => setState(() => _p = p),
      onNext: () => _go(_Step.injuries),
    ),
    _Step.injuries => _InjuryStep(
      profile: _p,
      onChanged: (p) => setState(() => _p = p),
      onNext: () => _go(_Step.photosIntro),
    ),
    _Step.photosIntro => _PhotosIntro(
      adult: _p.adultConsent,
      faceBlur: _p.faceBlur,
      onAdult: (v) => setState(() => _p = _p.copyWith(adultConsent: v)),
      onFaceBlur: (v) => setState(() => _p = _p.copyWith(faceBlur: v)),
      onNext: () async {
        // Face-blur preference must be known before the camera runs.
        await ref.read(servicesProvider).local.saveProfile(_p);
        _go(_Step.photos);
      },
      onSkip: () => _go(_Step.auth),
    ),
    _Step.photos => _PhotosStep(
      checkinId: _checkinId,
      initial: _baseline,
      weight: _p.weightKg,
      onDone: (photos) {
        setState(() => _baseline = photos);
        _go(_Step.auth);
      },
    ),
    _Step.auth => _AuthStep(
      returning: _returning,
      onDone: () async {
        if (!_returning) return _go(_Step.generating);
        if (await _restore()) return;
        _returning = false; // no saved profile: finish onboarding normally
        if (mounted) {
          showSnack(context, 'No saved plan yet — let’s set one up.');
        }
        _go(_Step.goal);
      },
    ),
    _Step.generating => _Generating(
      profile: _p,
      baseline: _baseline,
      checkinId: _checkinId,
      returning: _returning,
    ),
  };
}

// ---------------- O1 ----------------

class _Welcome extends StatefulWidget {
  const _Welcome({required this.onStart, required this.onSignIn});
  final VoidCallback onStart;
  final VoidCallback onSignIn;

  @override
  State<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<_Welcome> {
  final _pc = PageController();
  int _page = 0;

  static const _pages = [
    (
      Icons.fitness_center,
      'Train',
      'Today’s AI workout, prefilled. One tap per set — works offline.',
    ),
    (
      Icons.restaurant,
      'Eat',
      'Snap a meal, get macros in seconds. No food-diary fatigue.',
    ),
    (
      Icons.camera_alt_outlined,
      'Check in Sundays',
      '3 guided photos + weight + 60 seconds → your AI report and a plan that adapts.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'FORME AI',
          style: TextStyle(letterSpacing: 3, fontSize: 12, color: Brand.lime),
        ),
        const SizedBox(height: 18),
        Text.rich(
          const TextSpan(
            children: [
              TextSpan(text: 'See yourself\n'),
              TextSpan(
                text: 'changing.',
                style: TextStyle(color: Brand.lime),
              ),
            ],
          ),
          style: Theme.of(context).textTheme.headlineLarge
              ?.copyWith(fontSize: 42),
        ),
        const SizedBox(height: 10),
        const Text(
          'Your AI personal trainer watches your progress photos and adapts your plan.',
          style: TextStyle(color: Brand.textDim, fontSize: 16, height: 1.5),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: PageView(
            controller: _pc,
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              for (final (icon, title, body) in _pages)
                BrandCard(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: Brand.lime, size: 44),
                      const SizedBox(height: 12),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        body,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Brand.textDim,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _pages.length; i++)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _page ? Brand.lime : Brand.border,
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: widget.onStart,
          child: const Text('Get started'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: widget.onSignIn,
          child: const Text('I already have an account'),
        ),
        if (!kReleaseMode)
          Center(
            child: TextButton(
              onPressed: () => context.push('/debug'),
              child: const Text('Debug tools'),
            ),
          ),
      ],
    ),
  );
}

// ---------------- O2 ----------------

class _GoalStep extends StatelessWidget {
  const _GoalStep({required this.selected, required this.onPick});
  final Goal selected;
  final ValueChanged<Goal> onPick;

  static const _icons = {
    Goal.loseFat: Icons.local_fire_department,
    Goal.buildMuscle: Icons.fitness_center,
    Goal.recomp: Icons.autorenew,
    Goal.strength: Icons.trending_up,
  };

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Tag('O2 · Goal'),
      Text(
        'What’s your goal?',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 6),
      const Text(
        'Your plan adapts around it.',
        style: TextStyle(color: Brand.textDim),
      ),
      const SizedBox(height: 16),
      for (final g in Goal.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: BrandCard(
            onTap: () => onPick(g),
            border: g == selected ? Brand.lime : null,
            child: Row(
              children: [
                Icon(_icons[g], color: Brand.lime),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        g.blurb,
                        style: const TextStyle(color: Brand.textDim),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Brand.slate),
              ],
            ),
          ),
        ),
    ],
  );
}

// ---------------- O3 ----------------

class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.profile,
    required this.onChanged,
    required this.onNext,
  });
  final Profile profile;
  final ValueChanged<Profile> onChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final weightOk = Validators.weightKg(p.weightKg) == null;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Tag('O3 · Your setup'),
        Text(
          'Level, equipment & schedule',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        const Text('Experience', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ChoiceChips<Level>(
          options: const {
            Level.beginner: 'Beginner',
            Level.intermediate: 'Intermediate',
            Level.advanced: 'Advanced',
          },
          selected: {p.level},
          onTap: (l) => onChanged(p.copyWith(level: l)),
        ),
        const SizedBox(height: 18),
        const Text(
          'Equipment you have',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        ChoiceChips<String>(
          options: equipmentOptions,
          selected: p.equipment.toSet(),
          onTap: (e) {
            final s = p.equipment.toSet();
            s.contains(e) ? s.remove(e) : s.add(e);
            onChanged(
              p.copyWith(equipment: s.isEmpty ? ['bodyweight'] : s.toList()),
            );
          },
        ),
        const SizedBox(height: 18),
        Stepper2(
          label: 'Days per week',
          value: p.daysPerWeek.toDouble(),
          min: 2,
          max: 6,
          onChanged: (v) => onChanged(p.copyWith(daysPerWeek: v.round())),
        ),
        Stepper2(
          label: 'Minutes per session',
          value: p.mins.toDouble(),
          min: 20,
          max: 90,
          step: 5,
          unit: ' min',
          onChanged: (v) => onChanged(p.copyWith(mins: v.round())),
        ),
        const Divider(height: 28),
        const Text('About you', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ChoiceChips<String>(
          options: const {'female': 'Female', 'male': 'Male', 'other': 'Other'},
          selected: {?p.sex},
          onTap: (s) => onChanged(p.copyWith(sex: s)),
        ),
        const SizedBox(height: 8),
        Stepper2(
          label: 'Weight',
          value: p.weightKg ?? 75,
          min: 30,
          max: 300,
          step: 0.5,
          decimals: 1,
          unit: ' kg',
          onChanged: (v) => onChanged(p.copyWith(weightKg: v)),
        ),
        Stepper2(
          label: 'Height',
          value: p.heightCm ?? 172,
          min: 100,
          max: 250,
          unit: ' cm',
          onChanged: (v) => onChanged(p.copyWith(heightCm: v)),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            onChanged(
              p.copyWith(
                weightKg: p.weightKg ?? 75,
                heightCm: p.heightCm ?? 172,
              ),
            );
            onNext();
          },
          child: Text(weightOk ? 'Continue' : 'Continue'),
        ),
      ],
    );
  }
}

// ---------------- O4 ----------------

class _InjuryStep extends StatelessWidget {
  const _InjuryStep({
    required this.profile,
    required this.onChanged,
    required this.onNext,
  });
  final Profile profile;
  final ValueChanged<Profile> onChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Tag('O4 · Injuries'),
      Text(
        'Anything we should train around?',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 6),
      const Text(
        'We’ll swap exercises that load these areas.',
        style: TextStyle(color: Brand.textDim),
      ),
      const SizedBox(height: 16),
      ChoiceChips<String>(
        options: injuryOptions,
        selected: profile.injuries.toSet(),
        onTap: (i) {
          final s = profile.injuries.toSet();
          s.contains(i) ? s.remove(i) : s.add(i);
          onChanged(profile.copyWith(injuries: s.toList()));
        },
      ),
      const SizedBox(height: 16),
      TextFormField(
        initialValue: profile.injuryNotes,
        maxLength: 500,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'Anything else? (optional)',
        ),
        onChanged: (t) => onChanged(profile.copyWith(injuryNotes: t)),
      ),
      const Text(
        'Forme AI isn’t medical advice. If something hurts, check with a professional.',
        style: TextStyle(color: Brand.slate, fontSize: 12),
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: onNext,
        child: Text(profile.injuries.isEmpty ? 'None — continue' : 'Continue'),
      ),
    ],
  );
}

// ---------------- O5 ----------------

class _PhotosIntro extends StatelessWidget {
  const _PhotosIntro({
    required this.adult,
    required this.faceBlur,
    required this.onAdult,
    required this.onFaceBlur,
    required this.onNext,
    required this.onSkip,
  });
  final bool adult;
  final bool faceBlur;
  final ValueChanged<bool> onAdult;
  final ValueChanged<bool> onFaceBlur;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Tag('O5 · Baseline photos'),
      Text(
        'Your Week 0 photos',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      const Text(
        'Three guided photos today make your first before/after possible.',
        style: TextStyle(color: Brand.textDim, height: 1.5),
      ),
      const SizedBox(height: 16),
      for (final (icon, text) in const [
        (Icons.lock_outline, 'Encrypted, never public. Only you can see them.'),
        (
          Icons.face_retouching_off,
          'Face blur on by default — we only need your body shape.',
        ),
        (
          Icons.delete_outline,
          'Delete everything in one tap, anytime (purged within 24 h).',
        ),
        (
          Icons.phone_iphone,
          'Pose guide on-device: nothing is analysed until you submit.',
        ),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Brand.mint, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
            ],
          ),
        ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: faceBlur,
        onChanged: onFaceBlur,
        title: const Text('Blur my face'),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: adult,
        onChanged: (v) => onAdult(v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text(
          'I’m 18 or older and consent to storing my progress photos',
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: adult ? onNext : null,
        child: const Text('Take my 3 photos'),
      ),
      TextButton(onPressed: onSkip, child: const Text('Not now')),
    ],
  );
}

class _PhotosStep extends ConsumerWidget {
  const _PhotosStep({
    required this.checkinId,
    required this.initial,
    required this.weight,
    required this.onDone,
  });
  final String checkinId;
  final List<CheckinPhoto> initial;
  final double? weight;
  final ValueChanged<List<CheckinPhoto>> onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Tag('O5 · Baseline photos'),
      Text(
        'Front, side, back',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 6),
      const Text(
        'Fitted clothes, good light, phone at hip height. The guide tells you when '
        'you’re lined up.',
        style: TextStyle(color: Brand.textDim, height: 1.4),
      ),
      const SizedBox(height: 16),
      PhotoSetCapture(checkinId: checkinId, initial: initial, onDone: onDone),
    ],
  );
}

// ---------------- O6 ----------------

class _AuthStep extends ConsumerStatefulWidget {
  const _AuthStep({required this.onDone, required this.returning});
  final VoidCallback onDone;
  final bool returning;

  @override
  ConsumerState<_AuthStep> createState() => _AuthStepState();
}

class _AuthStepState extends ConsumerState<_AuthStep> {
  bool _busy = false;
  bool _email = false;
  bool _create = true;
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _form = GlobalKey<FormState>();

  Future<void> _run(Future<AppUser> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      widget.onDone();
    } on AuthCancelled {
      // User backed out; stay here.
    } on FirebaseAuthException catch (e) {
      if (mounted) showSnack(context, e.message ?? 'Sign-in failed');
    } catch (e) {
      if (mounted) showSnack(context, 'Sign-in failed — check your connection');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.read(servicesProvider).auth;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Tag('O6 · Account'),
        Text(
          widget.returning ? 'Welcome back' : 'Save your plan',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Your logs sync securely so you never lose progress.',
          style: TextStyle(color: Brand.textDim),
        ),
        const SizedBox(height: 22),
        if (auth.appleAvailable) ...[
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.white),
            onPressed: _busy ? null : () => _run(auth.signInWithApple),
            icon: const Icon(Icons.apple),
            label: const Text('Continue with Apple'),
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(auth.signInWithGoogle),
          icon: const Icon(Icons.g_mobiledata, size: 28),
          label: const Text('Continue with Google'),
        ),
        const SizedBox(height: 10),
        if (!_email)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => setState(() => _email = true),
            icon: const Icon(Icons.mail_outline),
            label: const Text('Continue with email'),
          )
        else
          Form(
            key: _form,
            child: Column(
              children: [
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(hintText: 'Email'),
                  validator: Validators.email,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _passCtrl,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(hintText: 'Password'),
                  validator: Validators.password,
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () {
                          if (!_form.currentState!.validate()) return;
                          _run(
                            () => auth.signInWithEmail(
                              _emailCtrl.text.trim(),
                              _passCtrl.text,
                              create: _create,
                            ),
                          );
                        },
                  child: Text(_create ? 'Create account' : 'Sign in'),
                ),
                TextButton(
                  onPressed: () => setState(() => _create = !_create),
                  child: Text(
                    _create
                        ? 'I have an account — sign in'
                        : 'New here? Create account',
                  ),
                ),
              ],
            ),
          ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        const SizedBox(height: 16),
        const Text(
          'By continuing you agree to the Terms and Privacy Policy.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Brand.slate, fontSize: 12),
        ),
      ],
    );
  }
}

// ---------------- O7 ----------------

class _Generating extends ConsumerStatefulWidget {
  const _Generating({
    required this.profile,
    required this.baseline,
    required this.checkinId,
    required this.returning,
  });
  final Profile profile;
  final List<CheckinPhoto> baseline;
  final String checkinId;
  final bool returning;

  @override
  ConsumerState<_Generating> createState() => _GeneratingState();
}

class _GeneratingState extends ConsumerState<_Generating> {
  static const _theater = Duration(seconds: 20);
  static const _lines = [
    'Reading your goal and schedule',
    'Matching exercises to your equipment',
    'Working around injuries',
    'Setting week 1 volume',
    'Planning progression + deload',
    'Calculating nutrition targets',
  ];
  int _done = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(_theater ~/ _lines.length, (t) {
      if (_done < _lines.length - 1) setState(() => _done++);
    });
    unawaited(_run());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final s = ref.read(servicesProvider);
    final repo = ref.read(repoProvider);
    final now = ref.read(clockProvider).now();
    final tz = await s.notifications.localTimezone();
    final profile = widget.profile.copyWith(
      timezone: tz,
      createdAt: now,
      name: s.auth.current?.displayName ?? widget.profile.name,
    );
    final started = DateTime.now();

    await repo.saveProfile(profile);
    // AI plan with template fallback; the theater runs ~20 s either way.
    await Future.wait([
      repo.createPlan(profile),
      Future<void>.delayed(s.demo ? const Duration(seconds: 4) : _theater),
    ]);
    if (widget.baseline.length == 3) {
      final c = Checkin(
        id: widget.checkinId,
        weekIndex: 0,
        createdAt: now,
        weightKg: profile.weightKg,
        photos: widget.baseline,
        baseline: true,
      );
      await repo.submitCheckin(c, aiReport: false);
      await s.local.write('baseline_ready', true);
    }
    await s.local.setOnboarded(true);
    unawaited(
      s.notifications.requestPermission().then(
        (_) => s.notifications.scheduleWorkoutReminders(
          hour: profile.reminderHour,
          weekdays: _weekdays(profile.daysPerWeek, now),
        ),
      ),
    );
    await s.analytics.log(Events.onboardingCompleted, {
      'baseline_photos': widget.baseline.length == 3 ? 1 : 0,
      'secs': DateTime.now().difference(started).inSeconds,
    });
    if (!mounted) return;
    setState(() => _done = _lines.length);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    // go() disposes this screen, so push through the router, not the context.
    final router = GoRouter.of(context);
    router.go('/today');
    // D7 opens right after the plan exists; closing it lands on T1.
    router.push('/paywall?placement=onboarding');
  }

  /// Weekdays (1=Mon) matching the plan's day offsets from today.
  static List<int> _weekdays(int dpw, DateTime start) {
    const offsets = {
      2: [0, 3],
      3: [0, 2, 4],
      4: [0, 1, 3, 4],
      5: [0, 1, 2, 4, 5],
      6: [0, 1, 2, 3, 4, 5],
    };
    return [
      for (final o in offsets[dpw.clamp(2, 6)]!)
        (start.weekday - 1 + o) % 7 + 1,
    ];
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        const Tag('O7 · Generating plan'),
        Text(
          'Building your plan…',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 24),
        ProgressBar(_done / _lines.length, height: 10),
        const SizedBox(height: 24),
        for (var i = 0; i < _lines.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: i < _done
                      ? const Icon(
                          Icons.check_circle,
                          color: Brand.lime,
                          key: ValueKey('d'),
                        )
                      : i == _done
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Icon(
                          Icons.radio_button_unchecked,
                          color: Brand.border,
                        ),
                ),
                const SizedBox(width: 12),
                Text(
                  _lines[i],
                  style: TextStyle(
                    color: i <= _done ? Brand.text : Brand.slate,
                  ),
                ),
              ],
            ),
          ),
        const Spacer(),
        const PrivacyNote(text: 'Tip: photos are encrypted, never public.'),
      ],
    ),
  );
}
