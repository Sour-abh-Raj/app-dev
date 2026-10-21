import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../domain/models.dart';
import '../../domain/training.dart';
import '../../domain/validators.dart';
import '../../services/analytics.dart';
import '../../widgets/common.dart';
import '../../widgets/morph.dart';
import 'capture.dart';

/// D4 Check-in wizard: pose guide → front/side/back → weight → 4-question
/// survey → AI report with morph slider. [reportFor] opens an existing report.
class CheckinWizard extends ConsumerStatefulWidget {
  const CheckinWizard({super.key, this.reportFor});
  final String? reportFor;

  @override
  ConsumerState<CheckinWizard> createState() => _CheckinWizardState();
}

class _CheckinWizardState extends ConsumerState<CheckinWizard> {
  int _step = 0;
  late Checkin _c;
  bool _healthPrefilled = false;
  Timer? _timeout;
  bool _timedOut = false;

  bool get _baselineMode => !ref
      .read(servicesProvider)
      .local
      .checkins
      .any((c) => c.photos.length == 3);

  @override
  void initState() {
    super.initState();
    final s = ref.read(servicesProvider);
    if (widget.reportFor != null &&
        s.local.checkin(widget.reportFor!) != null) {
      _c = s.local.checkin(widget.reportFor!)!;
      _step = 4;
      return;
    }
    final now = ref.read(clockProvider).now();
    final plan = s.local.plan;
    final baseline = _baselineMode;
    final week = baseline || plan == null ? 0 : positionOf(plan, now).week;
    final last = s.local.checkins.where((c) => c.weightKg != null).lastOrNull;
    _c = Checkin(
      id: 'w$week-${const Uuid().v4().substring(0, 8)}',
      weekIndex: week,
      createdAt: now,
      weightKg: last?.weightKg ?? s.local.profile?.weightKg ?? 75,
      baseline: baseline,
    );
    unawaited(_prefillWeight());
  }

  Future<void> _prefillWeight() async {
    final s = ref.read(servicesProvider);
    if (!(s.local.profile?.healthSync ?? false)) return;
    final w = await s.health.latestWeightKg();
    if (w != null && mounted) {
      setState(() {
        _c = _c.copyWith(weightKg: double.parse(w.toStringAsFixed(1)));
        _healthPrefilled = true;
      });
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    final access = ref.read(accessProvider);
    final repo = ref.read(repoProvider);
    final ai = access.aiPhotoReports && !_c.baseline;
    await repo.saveCheckinDraft(_c);
    _c = await repo.submitCheckin(_c, aiReport: ai);
    if (ai) {
      // p95 < 90 s with progress UI; after that we say "queued", never spin forever.
      _timeout = Timer(const Duration(seconds: 90), () {
        if (mounted) setState(() => _timedOut = true);
      });
      final plan = ref.read(planProvider);
      if (plan != null) {
        unawaited(
          repo.requestReplan(
            week: positionOf(plan, ref.read(clockProvider).now()).week + 1,
            survey: _c.survey,
          ),
        );
      }
    }
    setState(() => _step = 4);
  }

  @override
  Widget build(BuildContext context) {
    const titles = [
      'Pose guide',
      'Photos',
      'Weight',
      'Quick survey',
      'Your report',
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _c.baseline ? 'Baseline photos' : 'Week ${_c.weekIndex} check-in',
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Text(
                  '${_step + 1}/5 · ${titles[_step]}',
                  style: const TextStyle(color: Brand.textDim, fontSize: 12),
                ),
                const SizedBox(width: 10),
                Expanded(child: ProgressBar((_step + 1) / 5, height: 5)),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() => switch (_step) {
    0 => _GuideStep(onNext: () => setState(() => _step = 1)),
    1 => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        PhotoSetCapture(
          checkinId: _c.id,
          initial: _c.photos,
          onDone: (p) => setState(() {
            _c = _c.copyWith(photos: p);
            _step = 2;
          }),
        ),
      ],
    ),
    2 => _WeightStep(
      weight: _c.weightKg ?? 75,
      health: _healthPrefilled,
      onChanged: (w) => setState(() => _c = _c.copyWith(weightKg: w)),
      onNext: () {
        if (_c.baseline) {
          unawaited(_submit());
        } else {
          setState(() => _step = 3);
        }
      },
    ),
    3 => _SurveyStep(
      survey: _c.survey,
      onChanged: (s) => setState(() => _c = _c.copyWith(survey: s)),
      onNext: _submit,
    ),
    _ => _ReportStep(checkinId: _c.id, timedOut: _timedOut),
  };
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'Same pose, same place',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 10),
      for (final (i, t) in const [
        (Icons.wb_sunny_outlined, 'Bright, even light — face the window.'),
        (Icons.checkroom, 'Fitted clothes, same outfit each week.'),
        (
          Icons.straighten,
          'Phone upright at hip height, ~2.5 m away (or use the 5-s timer).',
        ),
        (
          Icons.accessibility_new,
          'Arms slightly away from your sides, relaxed stance.',
        ),
        (
          Icons.auto_fix_high,
          'The on-device guide turns lime when you’re lined up.',
        ),
      ])
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(i, color: Brand.mint),
          title: Text(t),
        ),
      const SizedBox(height: 8),
      const PrivacyNote(text: 'Encrypted, never public. Delete anytime.'),
      const SizedBox(height: 16),
      FilledButton(onPressed: onNext, child: const Text('I’m ready')),
    ],
  );
}

class _WeightStep extends StatelessWidget {
  const _WeightStep({
    required this.weight,
    required this.health,
    required this.onChanged,
    required this.onNext,
  });
  final double weight;
  final bool health;
  final ValueChanged<double> onChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Weight', style: Theme.of(context).textTheme.headlineSmall),
        const Text(
          'Morning, after the bathroom, before food — same each week.',
          style: TextStyle(color: Brand.textDim),
        ),
        const SizedBox(height: 24),
        Stepper2(
          label: 'Today',
          value: weight,
          step: 0.1,
          decimals: 1,
          min: 30,
          max: 300,
          unit: ' kg',
          onChanged: onChanged,
        ),
        if (health)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'From Health sync',
              style: TextStyle(color: Brand.mint, fontSize: 12),
            ),
          ),
        const Spacer(),
        FilledButton(
          onPressed: Validators.weightKg(weight) == null ? onNext : null,
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}

class _SurveyStep extends StatelessWidget {
  const _SurveyStep({
    required this.survey,
    required this.onChanged,
    required this.onNext,
  });
  final Survey survey;
  final ValueChanged<Survey> onChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    Widget q(
      String title,
      String low,
      String high,
      int value,
      ValueChanged<int> set,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 1; i <= 5; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Center(child: Text('$i')),
                      selected: value == i,
                      onSelected: (_) => set(i),
                    ),
                  ),
                ),
            ],
          ),
          Row(
            children: [
              Text(
                low,
                style: const TextStyle(color: Brand.slate, fontSize: 11),
              ),
              const Spacer(),
              Text(
                high,
                style: const TextStyle(color: Brand.slate, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('60 seconds', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 14),
        q(
          'How closely did you follow the plan?',
          'Barely',
          'Every session',
          survey.adherence,
          (v) => onChanged(survey.copyWith(adherence: v)),
        ),
        q(
          'Sleep this week',
          'Poor',
          'Great',
          survey.sleep,
          (v) => onChanged(survey.copyWith(sleep: v)),
        ),
        q(
          'Soreness',
          'None',
          'Very sore',
          survey.soreness,
          (v) => onChanged(survey.copyWith(soreness: v)),
        ),
        q(
          'Motivation',
          'Low',
          'Fired up',
          survey.motivation,
          (v) => onChanged(survey.copyWith(motivation: v)),
        ),
        FilledButton(onPressed: onNext, child: const Text('Get my AI report')),
      ],
    );
  }
}

class _ReportStep extends ConsumerStatefulWidget {
  const _ReportStep({required this.checkinId, required this.timedOut});
  final String checkinId;
  final bool timedOut;

  @override
  ConsumerState<_ReportStep> createState() => _ReportStepState();
}

class _ReportStepState extends ConsumerState<_ReportStep> {
  bool _logged = false;

  void _maybeLogConversion(Checkin c) {
    if (_logged || c.report == null) return;
    _logged = true;
    final s = ref.read(servicesProvider);
    if (s.local.read<bool>('conversion_logged') == true) return;
    unawaited(s.local.write('conversion_logged', true));
    unawaited(
      s.analytics.log(Events.conversionEventReached, {'week': c.weekIndex}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final checkins = ref.watch(checkinsProvider);
    final c = checkins.where((x) => x.id == widget.checkinId).firstOrNull;
    final access = ref.watch(accessProvider);
    if (c == null) return const SizedBox.shrink();
    final baseline = checkins
        .where((x) => x.photos.length == 3 && x.id != c.id)
        .firstOrNull;
    _maybeLogConversion(c);

    if (c.baseline) {
      return EmptyState(
        icon: Icons.check_circle,
        title: 'Baseline saved',
        body: 'Next Sunday you’ll see your first comparison.',
        cta: 'Done',
        onCta: () => context.go('/progress'),
      );
    }

    final pending =
        c.report == null &&
        (c.status == CheckinStatus.uploading ||
            c.status == CheckinStatus.analyzing ||
            c.status == CheckinStatus.queued);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (baseline != null && c.photos.length == 3) ...[
          if (access.timelineAndMorph)
            MorphSlider(
              before: baseline.photo('front')!,
              after: c.photo('front')!,
              beforeLabel: 'Wk ${baseline.weekIndex}',
              afterLabel: 'Wk ${c.weekIndex}',
            )
          else
            SideBySide(
              left: baseline.photo('front')!,
              right: c.photo('front')!,
              leftLabel: 'Week ${baseline.weekIndex}',
              rightLabel: 'Week ${c.weekIndex}',
            ),
          const SizedBox(height: 12),
        ],
        if (c.report != null) ...[
          Text(
            'Week ${c.weekIndex} report 🎉',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 22,
            runSpacing: 12,
            children: [
              for (final d in c.report!.deltas)
                DeltaText(
                  label: d.label,
                  value: d.display,
                  confidence: d.confidence,
                  good: d.metric == 'shoulder_waist_ratio'
                      ? d.change > 0
                      : d.change < 0,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(c.report!.summary, style: const TextStyle(height: 1.5)),
          if (c.report!.planChanges.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Next week',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final p in c.report!.planChanges)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.trending_up, color: Brand.lime),
                title: Text(p),
              ),
          ],
          BrandCard(
            child: Row(
              children: [
                const Icon(Icons.format_quote, color: Brand.mint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.report!.coachNote,
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.push(
              access.futureRender ? '/preview' : '/paywall?placement=settings',
            ),
            child: const Text('See future-physique preview'),
          ),
        ] else if (pending && !widget.timedOut) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Center(
            child: Text(
              c.status == CheckinStatus.uploading
                  ? 'Uploading photos securely…'
                  : 'Comparing with your baseline… usually under a minute',
              style: const TextStyle(color: Brand.textDim),
            ),
          ),
        ] else if (pending) ...[
          const InfoBanner(
            icon: Icons.schedule,
            text:
                'Analysis queued — your photos are saved. We’ll finish the report as soon as '
                'we can; it appears here and on Progress.',
          ),
        ] else if (c.status == CheckinStatus.manual) ...[
          const UpsellCard(
            title: 'Unlock your AI report',
            body: 'Waist and body-fat estimates, aligned morph and next week’s plan changes.',
            placement: 'cap_photo',
          ),
        ] else if (c.status == CheckinStatus.failed)
          InfoBanner(
            icon: Icons.error_outline,
            text: 'Couldn’t analyze — your check-in is saved.',
            action: 'Retry',
            onAction: () => ref.read(repoProvider).retryFailed(),
          ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: () => context.go('/progress'),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
