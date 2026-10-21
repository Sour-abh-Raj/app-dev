import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../domain/validators.dart';
import '../../widgets/common.dart';

/// D3 Meal result: macro bars, confidence chip, adjust steppers.
class MealResultScreen extends ConsumerStatefulWidget {
  const MealResultScreen({super.key, required this.mealId});
  final String mealId;

  @override
  ConsumerState<MealResultScreen> createState() => _MealResultScreenState();
}

class _MealResultScreenState extends ConsumerState<MealResultScreen> {
  Macros? _edit;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_analyze());
  }

  Future<void> _analyze() async {
    final local = ref.read(servicesProvider).local;
    final m = local.meal(widget.mealId);
    if (m == null || m.status != MealStatus.analyzing) return;
    setState(() => _waiting = true);
    final online = await ref.read(servicesProvider).isOnline();
    if (!online) {
      await local.saveMeal(m.copyWith(status: MealStatus.needsConnection));
    } else {
      // The queued op does the work; this just runs it now (≤15 s budget).
      await ref
          .read(repoProvider)
          .analyzeNow(m)
          .timeout(const Duration(seconds: 15), onTimeout: () => m);
      final after = local.meal(widget.mealId);
      if (after != null && after.status == MealStatus.analyzing) {
        await local.saveMeal(
          after.copyWith(status: MealStatus.needsConnection),
        );
      }
    }
    if (mounted) setState(() => _waiting = false);
  }

  Future<void> _retry() async {
    final local = ref.read(servicesProvider).local;
    final m = local.meal(widget.mealId);
    if (m == null) return;
    await local.saveMeal(m.copyWith(status: MealStatus.analyzing));
    await ref.read(repoProvider).retryFailed();
    await _analyze();
  }

  @override
  Widget build(BuildContext context) {
    final meal = ref
        .watch(mealsProvider)
        .where((m) => m.id == widget.mealId)
        .firstOrNull;
    if (meal == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Meal not found')),
      );
    }
    final plan = ref.watch(planProvider);
    final base =
        meal.macros ?? const Macros(kcal: 0, p: 0, c: 0, f: 0, model: 'manual');
    final m = _edit ?? base;
    final error = Validators.macros(kcal: m.kcal, p: m.p, c: m.c, f: m.f);
    final protein = (plan?.mesocycle.proteinG ?? 130).toDouble();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meal'),
        actions: [
          IconButton(
            tooltip: 'Delete meal',
            onPressed: () async {
              await ref.read(repoProvider).deleteMeal(meal.id);
              if (context.mounted) _leave(context);
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (meal.localPhoto != null && File(meal.localPhoto!).existsSync())
            ClipRRect(
              borderRadius: BorderRadius.circular(Brand.radius),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.file(File(meal.localPhoto!), fit: BoxFit.cover),
              ),
            ),
          const SizedBox(height: 12),
          _status(meal),
          if (meal.macros != null || meal.status != MealStatus.analyzing) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.name.isNotEmpty ? m.name : (meal.text ?? 'Meal'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                if (meal.ai != null)
                  Chip(
                    avatar: Icon(
                      Icons.verified,
                      size: 16,
                      color: meal.ai!.confidence >= 0.7
                          ? Brand.lime
                          : Brand.slate,
                    ),
                    label: Text(
                      '${(meal.ai!.confidence * 100).round()}% confidence',
                    ),
                  ),
              ],
            ),
            Text(
              '${m.kcal} kcal',
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            _MacroBar(label: 'Protein', grams: m.p, target: protein),
            _MacroBar(label: 'Carbs', grams: m.c, target: 250),
            _MacroBar(label: 'Fat', grams: m.f, target: 80),
            const Divider(height: 28),
            const Text('Adjust', style: TextStyle(fontWeight: FontWeight.w700)),
            Stepper2(
              label: 'Calories',
              value: m.kcal.toDouble(),
              step: 10,
              max: 5000,
              unit: ' kcal',
              onChanged: (v) =>
                  setState(() => _edit = m.copyWith(kcal: v.round())),
            ),
            Stepper2(
              label: 'Protein',
              value: m.p,
              step: 1,
              max: 400,
              unit: ' g',
              onChanged: (v) => setState(() => _edit = m.copyWith(p: v)),
            ),
            Stepper2(
              label: 'Carbs',
              value: m.c,
              step: 1,
              max: 800,
              unit: ' g',
              onChanged: (v) => setState(() => _edit = m.copyWith(c: v)),
            ),
            Stepper2(
              label: 'Fat',
              value: m.f,
              step: 1,
              max: 400,
              unit: ' g',
              onChanged: (v) => setState(() => _edit = m.copyWith(f: v)),
            ),
            if (_edit != null && error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(error, style: const TextStyle(color: Brand.danger)),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _edit != null && error != null
                  ? null
                  : () async {
                      if (_edit != null) {
                        await ref
                            .read(repoProvider)
                            .updateMeal(
                              meal.copyWith(
                                override: Macros(
                                  kcal: m.kcal,
                                  p: m.p,
                                  c: m.c,
                                  f: m.f,
                                  name: m.name,
                                ),
                                status: meal.status == MealStatus.analyzing
                                    ? null
                                    : MealStatus.done,
                              ),
                            );
                      }
                      if (context.mounted) _leave(context);
                    },
              child: const Text('Save'),
            ),
          ],
        ],
      ),
    );
  }

  static void _leave(BuildContext context) =>
      context.canPop() ? context.pop() : context.go('/eat');

  Widget _status(Meal meal) => switch (meal.status) {
    MealStatus.analyzing => Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            _waiting ? 'Analyzing your meal…' : 'Queued for analysis',
            style: const TextStyle(color: Brand.textDim),
          ),
        ],
      ),
    ),
    MealStatus.needsConnection => InfoBanner(
      icon: Icons.cloud_off,
      text: 'Needs connection — your meal is saved and will be analyzed when you’re online.',
      action: 'Retry',
      onAction: _retry,
    ),
    MealStatus.capReached => const Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: UpsellCard(
        title: 'Daily AI scans used',
        body: 'Your meal is logged. Enter macros below, or go Pro for AI on every meal.',
        placement: 'cap_meal',
      ),
    ),
    MealStatus.failed => InfoBanner(
      icon: Icons.error_outline,
      text: 'Couldn’t analyze this one — enter macros below.',
      action: 'Retry',
      onAction: _retry,
    ),
    MealStatus.done => const SizedBox.shrink(),
  };
}

class _MacroBar extends StatelessWidget {
  const _MacroBar({
    required this.label,
    required this.grams,
    required this.target,
  });
  final String label;
  final double grams;
  final double target;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label ${grams.round()} g',
          style: const TextStyle(color: Brand.textDim),
        ),
        const SizedBox(height: 4),
        ProgressBar(grams / target),
      ],
    ),
  );
}
