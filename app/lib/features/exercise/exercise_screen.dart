import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../domain/training.dart';
import '../../widgets/common.dart';
import '../../widgets/line_chart.dart';

/// D1 Exercise: demo video, cues, PR history, substitution picker.
class ExerciseScreen extends ConsumerWidget {
  const ExerciseScreen({super.key, required this.exId, this.workoutId});
  final String exId;
  final String? workoutId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libProvider);
    final ex = lib[exId];
    final profile = ref.watch(profileProvider);
    final workouts = ref.watch(workoutsProvider);
    if (ex == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Exercise not found')),
      );
    }
    final subs = lib.substitutesFor(
      exId,
      (profile?.equipment ?? const ['bodyweight']).toSet()
        ..remove('bodyweight'),
      (profile?.injuries ?? const []).toSet(),
    );
    final history = <(DateTime, double)>[];
    for (final w in workouts.reversed.where((w) => w.finished)) {
      final sets = w.sets.where((s) => s.exId == exId && s.done);
      if (sets.isEmpty) continue;
      final best = sets
          .map((s) => s.loadKg > 0 ? e1rm(s.loadKg, s.reps) : s.reps.toDouble())
          .reduce((a, b) => a > b ? a : b);
      history.add((w.finishedAt!, best));
    }
    return Scaffold(
      appBar: AppBar(title: Text(ex.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Demo(url: ex.demoVideoUrl, name: ex.name),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              Chip(label: Text(ex.muscle.replaceAll('_', ' '))),
              for (final e in ex.equipment)
                Chip(label: Text(equipmentOptions[e] ?? e)),
            ],
          ),
          const SizedBox(height: 8),
          Text('Cues', style: Theme.of(context).textTheme.titleLarge),
          for (final (i, c) in ex.cues.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 13,
                backgroundColor: Brand.lime,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(color: Brand.ink, fontSize: 12),
                ),
              ),
              title: Text(c),
            ),
          const SizedBox(height: 8),
          Text(
            ex.loadable ? 'Best estimated 1RM' : 'Best reps',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          BrandCard(
            child: LineChart(points: history, unit: ex.loadable ? ' kg' : ''),
          ),
          if (workoutId != null && subs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Swap exercise',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'Fits your equipment and injuries.',
              style: TextStyle(color: Brand.textDim),
            ),
            for (final s in subs.take(6))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.name),
                subtitle: Text(
                  '${s.muscle.replaceAll('_', ' ')} · ${s.equipment.join(', ')}',
                ),
                trailing: const Icon(Icons.swap_horiz),
                onTap: () async {
                  final local = ref.read(servicesProvider).local;
                  final w = local.workout(workoutId!);
                  if (w == null) return;
                  final swapped = [
                    for (final set in w.sets)
                      set.exId == exId && !set.done
                          ? set.copyWith(
                              exId: s.id,
                              loadKg: s.loadable ? set.loadKg : 0,
                            )
                          : set,
                  ];
                  await ref
                      .read(repoProvider)
                      .saveWorkout(w.copyWith(sets: swapped));
                  if (context.mounted) {
                    showSnack(context, 'Swapped to ${s.name}');
                    if (context.canPop()) context.pop();
                  }
                },
              ),
          ],
        ],
      ),
    );
  }
}

class _Demo extends StatefulWidget {
  const _Demo({required this.url, required this.name});
  final String url;
  final String name;

  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    if (widget.url.isNotEmpty) {
      _c = VideoPlayerController.networkUrl(Uri.parse(widget.url))
        ..setLooping(true)
        ..setVolume(0)
        ..initialize().then((_) {
          if (mounted) setState(() {});
          _c?.play();
        });
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Brand.radius),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: c != null && c.value.isInitialized
            ? VideoPlayer(c)
            : Container(
                color: Brand.card2,
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_circle_outline,
                      size: 48,
                      color: Brand.slate,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.url.isEmpty
                          ? 'Demo video not available — follow the cues below'
                          : 'Loading demo…',
                      style: const TextStyle(color: Brand.slate, fontSize: 12),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
