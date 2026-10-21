import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../domain/exercise_library.dart';
import '../../domain/models.dart';
import '../../domain/training.dart';
import '../../domain/validators.dart';
import '../../widgets/common.dart';

/// T1 Today: the AI session with every set prefilled; one tap logs a set.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(planProvider);
    final profile = ref.watch(profileProvider);
    final now = ref.watch(clockProvider).now();
    final workouts = ref.watch(workoutsProvider);
    final checkins = ref.watch(checkinsProvider);

    if (plan == null) {
      return EmptyState(
        icon: Icons.fitness_center,
        title: 'No plan yet',
        body: 'Build your plan from your goal, equipment and schedule.',
        cta: 'Build my plan',
        onCta: () async {
          if (profile == null) return context.go('/onboarding');
          await ref.read(repoProvider).createPlan(profile);
        },
      );
    }

    final pos = positionOf(plan, now);
    final session = sessionOn(plan, now);
    final missed = missedThisWeek(plan, workouts, now);
    final todayId = session == null
        ? null
        : workoutId(plan.version, pos.week, session.dayIndex);
    final current = todayId == null
        ? null
        : workouts.where((w) => w.id == todayId).firstOrNull;
    final streakN = streak(plan, workouts, now);
    final checkinDue =
        now.weekday == DateTime.sunday ||
        (pos.week > 1 &&
            !checkins.any((c) => c.weekIndex == pos.week - 1 && !c.baseline) &&
            pos.dayOffset == 6);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Tag('T1 · Today'),
                  Text(
                    'Week ${pos.week} · Day ${pos.dayNumber}',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ],
              ),
            ),
            if (streakN > 0)
              Chip(
                avatar: const Icon(
                  Icons.local_fire_department,
                  color: Brand.lime,
                  size: 18,
                ),
                label: Text('$streakN'),
              ),
            IconButton(
              tooltip: 'Settings',
              onPressed: () => context.push('/settings'),
              icon: const Icon(Icons.person_outline),
            ),
          ],
        ),
        if (plan.queued)
          const InfoBanner(
            icon: Icons.schedule,
            text: 'Analysis queued — template applied. Your AI plan replaces it when ready.',
          ),
        if (checkinDue)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: BrandCard(
              onTap: () => context.push('/checkin'),
              border: Brand.lime.withValues(alpha: 0.6),
              child: const Row(
                children: [
                  Icon(Icons.camera_alt_outlined, color: Brand.lime),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Sunday check-in · 3 photos + weight + 60 sec',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        if (missed != null && (current == null || !current.finished))
          _CatchupCard(plan: plan, session: missed, week: pos.week),
        if (session == null)
          _RestDay(plan: plan, now: now)
        else
          _SessionCard(
            plan: plan,
            session: session,
            week: pos.week,
            workout: current,
          ),
      ],
    );
  }
}

class _CatchupCard extends ConsumerWidget {
  const _CatchupCard({
    required this.plan,
    required this.session,
    required this.week,
  });
  final Plan plan;
  final PlanSession session;
  final int week;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: BrandCard(
      child: Row(
        children: [
          const Icon(Icons.bolt, color: Brand.mint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '20-min catch-up?',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  'A short ${session.name} — still counts.',
                  style: const TextStyle(color: Brand.textDim, fontSize: 13),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Brand.lime),
            onPressed: () async {
              final s = ref.read(servicesProvider);
              final w = startWorkout(
                plan: plan,
                session: catchupOf(session),
                week: week,
                now: ref.read(clockProvider).now(),
                history: s.local.workouts,
                lib: s.lib,
                catchup: true,
              );
              await ref.read(repoProvider).saveWorkout(w);
              if (context.mounted) {
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => DraggableScrollableSheet(
                    expand: false,
                    initialChildSize: 0.9,
                    builder: (_, sc) =>
                        _WorkoutBody(workoutId: w.id, scroll: sc),
                  ),
                );
              }
            },
            child: const Text('Start'),
          ),
        ],
      ),
    ),
  );
}

class _RestDay extends StatelessWidget {
  const _RestDay({required this.plan, required this.now});
  final Plan plan;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    PlanSession? next;
    var inDays = 0;
    for (var d = 1; d <= 7 && next == null; d++) {
      next = sessionOn(plan, now.add(Duration(days: d)));
      inDays = d;
    }
    return BrandCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.self_improvement, color: Brand.mint, size: 32),
          const SizedBox(height: 8),
          Text('Rest day', style: Theme.of(context).textTheme.titleLarge),
          const Text(
            'Recovery is training too. Walk, stretch, sleep well.',
            style: TextStyle(color: Brand.textDim),
          ),
          if (next != null) ...[
            const Divider(height: 24),
            Text(
              'Next: ${next.name} ${inDays == 1 ? 'tomorrow' : 'in $inDays days'} · ~${next.estMins} min',
              style: const TextStyle(color: Brand.textDim),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionCard extends ConsumerWidget {
  const _SessionCard({
    required this.plan,
    required this.session,
    required this.week,
    required this.workout,
  });
  final Plan plan;
  final PlanSession session;
  final int week;
  final Workout? workout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = workout;
    if (w != null && w.finished) {
      return BrandCard(
        onTap: () => context.push('/summary/${w.id}'),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Brand.lime, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${session.name} done',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    '${w.volumeKg.round()} kg volume${w.prs.isEmpty ? '' : ' · ${w.prs.length} PR'}',
                    style: const TextStyle(color: Brand.textDim),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      );
    }
    if (w == null) {
      // Prefilled preview; the first tap creates the workout log.
      final s = ref.read(servicesProvider);
      final draft = startWorkout(
        plan: plan,
        session: session,
        week: week,
        now: ref.read(clockProvider).now(),
        history: s.local.workouts,
        lib: s.lib,
      );
      return _WorkoutView(workout: draft, persisted: false);
    }
    return _WorkoutView(workout: w, persisted: true);
  }
}

/// Bottom-sheet variant (catch-up) that reads the workout from Hive.
class _WorkoutBody extends ConsumerWidget {
  const _WorkoutBody({required this.workoutId, required this.scroll});
  final String workoutId;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref
        .watch(workoutsProvider)
        .where((w) => w.id == workoutId)
        .firstOrNull;
    if (w == null) return const SizedBox.shrink();
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.all(16),
      children: [_WorkoutView(workout: w, persisted: true, popOnFinish: true)],
    );
  }
}

class _WorkoutView extends ConsumerWidget {
  const _WorkoutView({
    required this.workout,
    required this.persisted,
    this.popOnFinish = false,
  });
  final Workout workout;
  final bool persisted;
  final bool popOnFinish;

  Future<void> _save(WidgetRef ref, Workout w) =>
      ref.read(repoProvider).saveWorkout(w);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libProvider);
    final w = workout;
    final byEx = <String, List<SetLog>>{};
    for (final s in w.sets) {
      byEx.putIfAbsent(s.exId, () => []).add(s);
    }
    final done = w.sets.where((s) => s.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${w.sessionName} · ~${_mins(w)} min',
                style: const TextStyle(color: Brand.textDim),
              ),
            ),
            Text(
              '$done/${w.sets.length} sets',
              style: const TextStyle(color: Brand.textDim),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ProgressBar(w.sets.isEmpty ? 0 : done / w.sets.length),
        const SizedBox(height: 8),
        for (final e in byEx.entries)
          _ExerciseBlock(
            ex: lib[e.key],
            exId: e.key,
            sets: e.value,
            onOpen: () async {
              if (!persisted) await _save(ref, w);
              if (context.mounted) {
                context.push('/exercise/${e.key}?workout=${w.id}');
              }
            },
            onToggle: (set) async {
              final now = ref.read(clockProvider).now();
              final updated = [
                for (final s in w.sets)
                  s.exId == set.exId && s.setN == set.setN
                      ? s.copyWith(done: !s.done, ts: now)
                      : s,
              ];
              await _save(
                ref,
                w.copyWith(sets: updated, startedAt: w.startedAt ?? now),
              );
              if (!set.done && context.mounted) {
                HapticFeedback.mediumImpact();
                final rest = _restFor(ref, set.exId);
                unawaited(showRestTimer(context, rest));
              }
            },
            onEdit: (set) async {
              final edited = await showSetEditor(context, set);
              if (edited == null) return;
              await _save(
                ref,
                w.copyWith(
                  sets: [
                    for (final s in w.sets)
                      s.exId == set.exId && s.setN == set.setN ? edited : s,
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: done == 0
              ? null
              : () async {
                  // Grab navigation first: saving rebuilds Today and
                  // unmounts this view before the push would run.
                  final router = GoRouter.of(context);
                  final nav = Navigator.of(context);
                  final repo = ref.read(repoProvider);
                  final finished = await repo.finishWorkout(w);
                  if (popOnFinish) nav.pop();
                  router.push('/summary/${finished.id}');
                },
          child: const Text('Finish workout'),
        ),
      ],
    );
  }

  static int _mins(Workout w) => (w.sets.length * 2.2).round();

  int _restFor(WidgetRef ref, String exId) {
    final plan = ref.read(planProvider);
    if (plan == null) return 60;
    for (final week in plan.mesocycle.weeks) {
      for (final s in week.sessions) {
        for (final e in s.exercises) {
          if (e.exId == exId) return e.restS;
        }
      }
    }
    return 60;
  }
}

class _ExerciseBlock extends StatelessWidget {
  const _ExerciseBlock({
    required this.ex,
    required this.exId,
    required this.sets,
    required this.onOpen,
    required this.onToggle,
    required this.onEdit,
  });
  final Exercise? ex;
  final String exId;
  final List<SetLog> sets;
  final VoidCallback onOpen;
  final ValueChanged<SetLog> onToggle;
  final ValueChanged<SetLog> onEdit;

  @override
  Widget build(BuildContext context) {
    final timed = ex?.timed ?? false;
    final first = sets.first;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onOpen,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${ex?.name ?? exId}  ${sets.length}×${first.reps}${timed ? 's' : ''}'
                      '${first.loadKg > 0 ? ' · ${_kg(first.loadKg)}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const Icon(Icons.info_outline, size: 18, color: Brand.slate),
                ],
              ),
            ),
            const SizedBox(height: 4),
            for (final s in sets)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Material(
                  color: Brand.chip,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: s.done ? Brand.lime : Colors.transparent,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    onTap: () => onEdit(s),
                    title: Text(
                      'Set ${s.setN}   ${s.reps}${timed ? ' s' : ' reps'}'
                      '${s.loadKg > 0 ? '  ×  ${_kg(s.loadKg)}' : ''}',
                    ),
                    trailing: Semantics(
                      label: s.done
                          ? 'Undo set ${s.setN}'
                          : 'Log set ${s.setN}',
                      button: true,
                      child: IconButton(
                        onPressed: () => onToggle(s),
                        icon: Icon(
                          s.done
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: s.done ? Brand.lime : Brand.slate,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _kg(double v) =>
      '${v % 1 == 0 ? v.toInt() : v.toStringAsFixed(1)} kg';
}

Future<SetLog?> showSetEditor(BuildContext context, SetLog set) =>
    showModalBottomSheet<SetLog>(
      context: context,
      builder: (ctx) {
        var reps = set.reps.toDouble();
        var load = set.loadKg;
        return StatefulBuilder(
          builder: (ctx, setState) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Set ${set.setN}',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Stepper2(
                  label: 'Reps',
                  value: reps,
                  min: 0,
                  max: 300,
                  onChanged: (v) => setState(() => reps = v),
                ),
                Stepper2(
                  label: 'Load',
                  value: load,
                  min: 0,
                  max: 400,
                  step: 2.5,
                  decimals: 1,
                  unit: ' kg',
                  onChanged: (v) => setState(() => load = v),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      Validators.reps(reps.round()) == null &&
                          Validators.loadKg(load) == null
                      ? () => Navigator.pop(
                          ctx,
                          set.copyWith(reps: reps.round(), loadKg: load),
                        )
                      : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        );
      },
    );

/// Rest timer sheet: counts down, +15 s, skip.
Future<void> showRestTimer(BuildContext context, int seconds) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _RestTimer(seconds: seconds),
    );

class _RestTimer extends StatefulWidget {
  const _RestTimer({required this.seconds});
  final int seconds;

  @override
  State<_RestTimer> createState() => _RestTimerState();
}

class _RestTimerState extends State<_RestTimer> {
  late int _left = widget.seconds;
  late int _total = widget.seconds;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_left <= 1) {
        HapticFeedback.heavyImpact();
        _t?.cancel();
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Rest', style: TextStyle(color: Brand.textDim)),
        const SizedBox(height: 10),
        Ring(
          value: _left / _total,
          size: 150,
          child: Text(
            '${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() {
                  _left += 15;
                  _total += 15;
                }),
                child: const Text('+15 s'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Skip'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
