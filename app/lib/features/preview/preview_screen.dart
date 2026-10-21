import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../domain/models.dart';
import '../../widgets/common.dart';

/// D5 Future-physique preview. Iteration-1: the render endpoint is a quota-
/// checked stub returning a placeholder; the $1.99 3-pack upsell is stubbed.
class PreviewScreen extends ConsumerStatefulWidget {
  const PreviewScreen({super.key});

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  bool _busy = false;
  String? _result;
  String? _error;
  bool _capped = false;

  Future<void> _render() async {
    final s = ref.read(servicesProvider);
    final latest = s.local.checkins
        .where((c) => c.photos.length == 3)
        .lastOrNull;
    final front = latest?.photo('front')?.path;
    if (front == null) {
      setState(
        () => _error = 'Take a check-in first — the preview starts from your latest photo.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final goal = s.local.profile?.goal.label ?? 'fitter';
      final month = DateTime.now().toIso8601String().substring(0, 7);
      _result = await s.api.renderPreview(
        photoPath: front,
        goal: goal,
        idemKey: 'preview-${latest!.id}-$month',
      );
    } on CapReachedError {
      _capped = true;
    } on OfflineError {
      _error = 'Needs connection — try again when you’re online.';
    } on AppError catch (e) {
      _error = 'Couldn’t render right now (${e.message}).';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Future physique')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Tag('D5 · Preview'),
        Text(
          'Where your plan is heading',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _panel('NOW', 'latest check-in', Brand.card2, Brand.text),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _panel(
                _result == null ? '12 WEEKS' : 'PREVIEW',
                _result == null ? 'tap generate' : 'illustrative render',
                null,
                Brand.ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Illustrative only — not a prediction or medical advice.',
          style: TextStyle(color: Brand.slate, fontSize: 12),
        ),
        const SizedBox(height: 16),
        if (_error != null) InfoBanner(icon: Icons.info_outline, text: _error!),
        if (_capped)
          const UpsellCard(
            title: 'This month’s render is used',
            body: 'Pro includes 1 render a month. Extra 3-packs (\$1.99) are coming soon.',
            placement: 'settings',
          )
        else
          FilledButton.icon(
            onPressed: _busy ? null : _render,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_result == null ? 'Generate preview' : 'Regenerate'),
          ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: null, // consumable 3-pack: stubbed in iteration-1
          child: const Text('Extra renders · \$1.99 / 3-pack (coming soon)'),
        ),
      ],
    ),
  );

  Widget _panel(String title, String sub, Color? color, Color fg) =>
      AspectRatio(
        aspectRatio: 3 / 4,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            gradient: color == null
                ? const LinearGradient(
                    colors: [Brand.lime, Brand.mint],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(Brand.radius),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
              Text(
                sub,
                style: TextStyle(
                  color: fg.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
}
