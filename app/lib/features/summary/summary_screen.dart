import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../domain/training.dart';
import '../../widgets/common.dart';

/// D2 Summary: volume, PR badges, share, streak++.
class SummaryScreen extends ConsumerWidget {
  const SummaryScreen({super.key, required this.workoutId});
  final String workoutId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref
        .watch(workoutsProvider)
        .where((w) => w.id == workoutId)
        .firstOrNull;
    final plan = ref.watch(planProvider);
    final lib = ref.watch(libProvider);
    final now = ref.watch(clockProvider).now();
    if (w == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Workout not found')),
      );
    }
    final streakN = plan == null
        ? 0
        : streak(plan, ref.watch(workoutsProvider), now);
    final doneSets = w.sets.where((s) => s.done).length;
    final mins = w.startedAt != null && w.finishedAt != null
        ? w.finishedAt!.difference(w.startedAt!).inMinutes
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Workout complete')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Tag('D2 · Summary'),
          Text(
            'Nice work 💪',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          Text(w.sessionName, style: const TextStyle(color: Brand.textDim)),
          const SizedBox(height: 18),
          Row(
            children: [
              _Stat(label: 'Volume', value: '${w.volumeKg.round()} kg'),
              _Stat(label: 'Sets', value: '$doneSets'),
              _Stat(label: 'Streak', value: '🔥 $streakN'),
              if (mins != null) _Stat(label: 'Time', value: '$mins min'),
            ],
          ),
          const SizedBox(height: 18),
          if (w.prs.isNotEmpty) ...[
            Text(
              'Personal records',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final pr in w.prs)
                  Chip(
                    avatar: const Icon(
                      Icons.emoji_events,
                      color: Brand.ink,
                      size: 18,
                    ),
                    backgroundColor: Brand.lime,
                    label: Text(
                      lib.nameOf(pr),
                      style: const TextStyle(
                        color: Brand.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ] else
            const Text(
              'No PRs today — consistency is what changes you.',
              style: TextStyle(color: Brand.textDim),
            ),
          const SizedBox(height: 28),
          OutlinedButton.icon(
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                text:
                    'Just finished ${w.sessionName} on Forme AI — ${w.volumeKg.round()} kg moved'
                    '${w.prs.isEmpty ? '' : ', ${w.prs.length} PR${w.prs.length == 1 ? '' : 's'}'}'
                    '. Streak: $streakN 🔥',
              ),
            ),
            icon: const Icon(Icons.ios_share),
            label: const Text('Share'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () => context.go('/today'),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
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
