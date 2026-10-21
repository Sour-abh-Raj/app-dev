import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../domain/models.dart';
import '../../domain/training.dart';
import '../../widgets/common.dart';
import '../../widgets/line_chart.dart';
import '../../widgets/morph.dart';

/// T3 Progress: weight trend, streak, check-in timeline, check-in CTA.
class ProgressScreen extends ConsumerStatefulWidget {
  const ProgressScreen({super.key});

  @override
  ConsumerState<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends ConsumerState<ProgressScreen> {
  String _angle = 'front';

  @override
  Widget build(BuildContext context) {
    final checkins = ref.watch(checkinsProvider);
    final profile = ref.watch(profileProvider);
    final plan = ref.watch(planProvider);
    final access = ref.watch(accessProvider);
    final now = ref.watch(clockProvider).now();
    final streakN = plan == null
        ? 0
        : streak(plan, ref.watch(workoutsProvider), now);
    final finished = ref
        .watch(workoutsProvider)
        .where((w) => w.finished)
        .length;

    final weights = <(DateTime, double)>[
      if (profile?.weightKg != null &&
          profile?.createdAt != null &&
          !checkins.any((c) => c.baseline && c.weightKg != null))
        (profile!.createdAt!, profile.weightKg!),
      for (final c in checkins)
        if (c.weightKg != null) (c.createdAt, c.weightKg!),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    final withPhotos = checkins.where((c) => c.photos.length == 3).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const Tag('T3 · Progress'),
        Text(
          'See yourself changing',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(label: 'Streak', value: '🔥 $streakN'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(label: 'Workouts', value: '$finished'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                label: 'Check-ins',
                value: '${checkins.where((c) => !c.baseline).length}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        BrandCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Weight',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              LineChart(points: weights, unit: ' kg'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => context.push('/checkin'),
          icon: const Icon(Icons.camera_alt_outlined),
          label: const Text('Start check-in'),
        ),
        const SizedBox(height: 16),
        if (withPhotos.isEmpty)
          EmptyState(
            icon: Icons.photo_camera_front_outlined,
            title: 'Your timeline starts with one photo set',
            body: 'Front, side and back — encrypted, never public.',
            cta: 'Take baseline photos',
            onCta: () => context.push('/checkin'),
          )
        else ...[
          Text('Timeline', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'front', label: Text('Front')),
              ButtonSegment(value: 'side', label: Text('Side')),
              ButtonSegment(value: 'back', label: Text('Back')),
            ],
            selected: {_angle},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _angle = s.first),
          ),
          const SizedBox(height: 8),
          if (withPhotos.length >= 2) ...[
            if (access.timelineAndMorph)
              MorphSlider(
                before: withPhotos.first.photo(_angle)!,
                after: withPhotos.last.photo(_angle)!,
                beforeLabel: 'Wk ${withPhotos.first.weekIndex}',
                afterLabel: 'Wk ${withPhotos.last.weekIndex}',
              )
            else ...[
              SideBySide(
                left: withPhotos.first.photo(_angle)!,
                right: withPhotos.last.photo(_angle)!,
                leftLabel: 'Week ${withPhotos.first.weekIndex}',
                rightLabel: 'Week ${withPhotos.last.weekIndex}',
              ),
              const SizedBox(height: 8),
              const UpsellCard(
                title: 'Aligned morph + AI report',
                body: 'Pro lines up your photos automatically and estimates waist and body-fat change.',
                placement: 'settings',
              ),
            ],
            const SizedBox(height: 12),
          ],
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 3 / 4,
            children: [
              for (final c in withPhotos.reversed)
                _TimelineTile(
                  checkin: c,
                  angle: _angle,
                  onTap: () => context.push('/checkin?report=${c.id}'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (access.futureRender)
            OutlinedButton.icon(
              onPressed: () => context.push('/preview'),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Future-physique preview'),
            ),
        ],
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => BrandCard(
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        Text(label, style: const TextStyle(color: Brand.slate, fontSize: 12)),
      ],
    ),
  );
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({
    required this.checkin,
    required this.angle,
    required this.onTap,
  });
  final Checkin checkin;
  final String angle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = checkin.photo(angle);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (p != null && File(p.localPath).existsSync())
              Image.file(File(p.localPath), fit: BoxFit.cover, cacheWidth: 300)
            else
              Container(color: Brand.card2),
            Positioned(
              left: 6,
              bottom: 4,
              child: Text(
                checkin.baseline ? 'Baseline' : 'Wk ${checkin.weekIndex}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
            if (checkin.report != null)
              const Positioned(
                right: 4,
                top: 4,
                child: Icon(Icons.auto_awesome, color: Brand.lime, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}
