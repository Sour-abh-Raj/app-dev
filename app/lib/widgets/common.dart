import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/theme.dart';

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(fontSize: 11, letterSpacing: 1, color: Brand.slate),
  );
}

class BrandCard extends StatelessWidget {
  const BrandCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = 14,
    this.color,
    this.border,
  });
  final Widget child;
  final VoidCallback? onTap;
  final double padding;
  final Color? color;
  final Color? border;

  @override
  Widget build(BuildContext context) => Material(
    color: color ?? Brand.card2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Brand.radius),
      side: border == null
          ? BorderSide.none
          : BorderSide(color: border!, width: 1.5),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: EdgeInsets.all(padding), child: child),
    ),
  );
}

/// Lime→mint progress bar.
class ProgressBar extends StatelessWidget {
  const ProgressBar(this.value, {super.key, this.height = 8});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(height / 2),
    child: Container(
      height: height,
      color: Brand.track,
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0, 1).toDouble(),
        child: Container(
          decoration: const BoxDecoration(gradient: Brand.progressGradient),
        ),
      ),
    ),
  );
}

/// Lime progress ring with a centred label.
class Ring extends StatelessWidget {
  const Ring({
    super.key,
    required this.value,
    required this.child,
    this.size = 110,
    this.stroke = 10,
    this.color = Brand.lime,
  });
  final double value;
  final Widget child;
  final double size;
  final double stroke;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _RingPainter(value.clamp(0, 1).toDouble(), stroke, color),
      child: Center(child: child),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.stroke, this.color);
  final double value;
  final double stroke;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    final track = Paint()
      ..color = Brand.track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(r, 0, 2 * math.pi, false, track);
    canvas.drawArc(r, -math.pi / 2, 2 * math.pi * value, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color;
}

/// Designed empty state: one message, one CTA.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.cta,
    required this.onCta,
  });
  final IconData icon;
  final String title;
  final String body;
  final String cta;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: Brand.lime.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Brand.lime, size: 36),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Brand.textDim, height: 1.5),
        ),
        const SizedBox(height: 22),
        FilledButton(onPressed: onCta, child: Text(cta)),
      ],
    ),
  );
}

/// Inline upsell — never blocks the free path.
class UpsellCard extends StatelessWidget {
  const UpsellCard({
    super.key,
    required this.title,
    required this.body,
    this.placement = 'cap',
    this.secondary,
    this.onSecondary,
  });
  final String title;
  final String body;
  final String placement;
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => BrandCard(
    border: Brand.lime.withValues(alpha: 0.5),
    color: Brand.lime.withValues(alpha: 0.06),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.bolt, color: Brand.lime, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          body,
          style: const TextStyle(
            color: Brand.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => context.push('/paywall?placement=$placement'),
              child: const Text('See Pro'),
            ),
            if (secondary != null)
              TextButton(onPressed: onSecondary, child: Text(secondary!)),
          ],
        ),
      ],
    ),
  );
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
    this.color = Brand.card2,
  });
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: Brand.textDim),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        if (action != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Brand.lime),
            onPressed: onAction,
            child: Text(action!),
          ),
      ],
    ),
  );
}

/// − value + stepper used for sets, reps, load, days, minutes, macros.
class Stepper2 extends StatelessWidget {
  const Stepper2({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.step = 1,
    this.min = 0,
    this.max = 999,
    this.unit = '',
    this.decimals = 0,
  });
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double step;
  final double min;
  final double max;
  final String unit;
  final int decimals;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: Brand.textDim)),
      ),
      _btn(
        Icons.remove,
        value - step >= min - 1e-9 ? () => onChanged(value - step) : null,
        '$label minus',
      ),
      SizedBox(
        width: 84,
        child: Text(
          '${value.toStringAsFixed(decimals)}$unit',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
      ),
      _btn(
        Icons.add,
        value + step <= max + 1e-9 ? () => onChanged(value + step) : null,
        '$label plus',
      ),
    ],
  );

  Widget _btn(IconData icon, VoidCallback? onTap, String semantics) =>
      Semantics(
        label: semantics,
        button: true,
        child: IconButton.filledTonal(
          onPressed: onTap,
          icon: Icon(icon),
          style: IconButton.styleFrom(backgroundColor: Brand.chip),
        ),
      );
}

class ChoiceChips<T> extends StatelessWidget {
  const ChoiceChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onTap,
  });
  final Map<T, String> options;
  final Set<T> selected;
  final ValueChanged<T> onTap;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final e in options.entries)
        ChoiceChip(
          label: Text(e.value),
          selected: selected.contains(e.key),
          onSelected: (_) => onTap(e.key),
        ),
    ],
  );
}

class PrivacyNote extends StatelessWidget {
  const PrivacyNote({
    super.key,
    this.text = 'Photos are encrypted, never public.',
  });
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.lock_outline, size: 14, color: Brand.slate),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: Brand.slate),
        ),
      ),
    ],
  );
}

/// Big bold delta, lime when it moves toward the goal. Confidence shown.
class DeltaText extends StatelessWidget {
  const DeltaText({
    super.key,
    required this.label,
    required this.value,
    required this.confidence,
    this.good = true,
  });
  final String label;
  final String value;
  final double confidence;
  final bool good;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Brand.textDim, fontSize: 12)),
      Text(
        value,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: good ? Brand.lime : Brand.text,
        ),
      ),
      Text(
        '${(confidence * 100).round()}% confidence',
        style: const TextStyle(color: Brand.slate, fontSize: 11),
      ),
    ],
  );
}

void showSnack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
