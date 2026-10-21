import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../domain/models.dart';
import '../../domain/validators.dart';
import '../../services/analytics.dart';
import '../../widgets/common.dart';

/// Meals that used (or are using) an AI analysis today.
int aiMealsToday(List<Meal> meals, DateTime now) => meals
    .where(
      (m) =>
          dateOnly(m.loggedAt) == dateOnly(now) &&
          m.idemKey != null &&
          m.status != MealStatus.capReached &&
          (m.ai != null ||
              m.status == MealStatus.analyzing ||
              m.status == MealStatus.needsConnection),
    )
    .length;

/// T2 Eat: daily rings, today's meals, camera FAB (snap → macros in <15 s).
class EatScreen extends ConsumerWidget {
  const EatScreen({super.key});

  static Future<void> snap(
    BuildContext context,
    WidgetRef ref, {
    bool fromGallery = false,
  }) async {
    final s = ref.read(servicesProvider);
    final now = ref.read(clockProvider).now();
    final access = ref.read(accessProvider);
    final x = await ImagePicker().pickImage(
      source: fromGallery ? ImageSource.gallery : ImageSource.camera,
      maxWidth: 2048,
      imageQuality: 90,
    );
    if (x == null) return;
    final id = const Uuid().v4();
    final path = await s.photos.saveMealPhoto(x.path, id);
    final underCap = aiMealsToday(s.local.meals, now) < access.aiMealsPerDay;
    final meal = await ref
        .read(repoProvider)
        .logMeal(localPhoto: path, analyze: underCap);
    if (!underCap) await s.analytics.log(Events.capHit('meal'));
    if (context.mounted) context.push('/meal/${meal.id}');
  }

  static Future<void> describe(BuildContext context, WidgetRef ref) async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final c = TextEditingController();
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: c,
                autofocus: true,
                maxLength: 500,
                decoration: const InputDecoration(
                  hintText: 'e.g. 2 eggs on toast, black coffee',
                ),
              ),
              FilledButton(
                onPressed: () {
                  if (Validators.mealText(c.text) == null) {
                    Navigator.pop(ctx, c.text.trim());
                  }
                },
                child: const Text('Log meal'),
              ),
            ],
          ),
        );
      },
    );
    if (text == null) return;
    final s = ref.read(servicesProvider);
    final underCap =
        aiMealsToday(s.local.meals, ref.read(clockProvider).now()) <
        ref.read(accessProvider).aiMealsPerDay;
    final meal = await ref
        .read(repoProvider)
        .logMeal(text: text, analyze: underCap);
    if (context.mounted) context.push('/meal/${meal.id}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final meals = ref
        .watch(mealsProvider)
        .where((m) => dateOnly(m.loggedAt) == dateOnly(now))
        .toList();
    final plan = ref.watch(planProvider);
    final access = ref.watch(accessProvider);
    final kcalTarget = plan?.mesocycle.kcalTarget ?? 2200;
    final proteinTarget = plan?.mesocycle.proteinG ?? 130;
    final kcal = meals.fold<int>(0, (a, m) => a + (m.macros?.kcal ?? 0));
    final protein = meals.fold<double>(0, (a, m) => a + (m.macros?.p ?? 0));
    final carbs = meals.fold<double>(0, (a, m) => a + (m.macros?.c ?? 0));
    final fat = meals.fold<double>(0, (a, m) => a + (m.macros?.f ?? 0));
    final aiUsed = aiMealsToday(ref.watch(mealsProvider), now);

    return Scaffold(
      floatingActionButton: FloatingActionButton.large(
        tooltip: 'Snap a meal',
        backgroundColor: Brand.lime,
        foregroundColor: Brand.ink,
        onPressed: () => snap(context, ref),
        child: const Icon(Icons.camera_alt, size: 36),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        children: [
          const Tag('T2 · Eat'),
          Text('Today', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Ring(
                value: kcal / kcalTarget,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$kcal',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                    Text(
                      '/ $kcalTarget kcal',
                      style: const TextStyle(color: Brand.slate, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Ring(
                value: protein / proteinTarget,
                color: Brand.mint,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${protein.round()}g',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                    Text(
                      '/ ${proteinTarget}g protein',
                      style: const TextStyle(color: Brand.slate, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Carbs ${carbs.round()}g · Fat ${fat.round()}g',
              style: const TextStyle(color: Brand.textDim),
            ),
          ),
          const SizedBox(height: 12),
          if (!access.pro && aiUsed >= access.aiMealsPerDay)
            UpsellCard(
              title: 'You’ve used today’s 3 AI meal scans',
              body: 'Keep logging manually for free, or go Pro for AI macros on every meal.',
              placement: 'cap_meal',
              secondary: 'Log manually',
              onSecondary: () => describe(context, ref),
            ),
          if (meals.isEmpty)
            EmptyState(
              icon: Icons.restaurant,
              title: 'No meals logged today',
              body: 'Snap your plate — macros in seconds. Or describe it in words.',
              cta: 'Snap your first meal',
              onCta: () => snap(context, ref),
            )
          else ...[
            for (final m in meals) _MealTile(meal: m),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => describe(context, ref),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Describe'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => snap(context, ref, fromGallery: true),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('From gallery'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (access.weeklyNutritionReports)
            _WeeklyNutrition(
              meals: ref.watch(mealsProvider),
              now: now,
              kcalTarget: kcalTarget,
            )
          else
            const UpsellCard(
              title: 'Weekly nutrition report',
              body: 'See your weekly averages against your targets, with one change to make next week.',
              placement: 'settings',
            ),
        ],
      ),
    );
  }
}

class _MealTile extends StatelessWidget {
  const _MealTile({required this.meal});
  final Meal meal;

  @override
  Widget build(BuildContext context) {
    final m = meal.macros;
    final subtitle = switch (meal.status) {
      MealStatus.analyzing => 'Analyzing…',
      MealStatus.needsConnection =>
        'Needs connection — will analyze when online',
      MealStatus.capReached => 'Logged · add macros manually',
      MealStatus.failed => 'Couldn’t analyze · tap to enter macros',
      MealStatus.done =>
        m == null
            ? 'No macros yet'
            : 'P ${m.p.round()}g · C ${m.c.round()}g · F ${m.f.round()}g',
    };
    return Card(
      child: ListTile(
        onTap: () => context.push('/meal/${meal.id}'),
        leading: const CircleAvatar(
          backgroundColor: Brand.chip,
          child: Icon(Icons.restaurant, color: Brand.lime),
        ),
        title: Text(
          m?.name.isNotEmpty == true ? m!.name : (meal.text ?? 'Meal'),
        ),
        subtitle: Text(subtitle),
        trailing: Text(
          m == null ? '—' : '${m.kcal} kcal',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _WeeklyNutrition extends StatelessWidget {
  const _WeeklyNutrition({
    required this.meals,
    required this.now,
    required this.kcalTarget,
  });
  final List<Meal> meals;
  final DateTime now;
  final int kcalTarget;

  @override
  Widget build(BuildContext context) {
    final start = dateOnly(now).subtract(const Duration(days: 6));
    final week = meals.where((m) => !m.loggedAt.isBefore(start)).toList();
    final days = week.map((m) => dateOnly(m.loggedAt)).toSet().length;
    final kcal = week.fold<int>(0, (a, m) => a + (m.macros?.kcal ?? 0));
    final protein = week.fold<double>(0, (a, m) => a + (m.macros?.p ?? 0));
    final avg = days == 0 ? 0 : kcal ~/ days;
    return BrandCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This week',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '$avg kcal/day avg · ${days == 0 ? 0 : (protein / days).round()} g protein/day · '
            '$days day${days == 1 ? '' : 's'} logged',
            style: const TextStyle(color: Brand.textDim),
          ),
          const SizedBox(height: 8),
          ProgressBar(days == 0 ? 0 : avg / kcalTarget),
        ],
      ),
    );
  }
}
