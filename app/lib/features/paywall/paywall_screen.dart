import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../services/analytics.dart';
import '../../services/purchases_service.dart';
import '../../widgets/common.dart';

/// D7 Paywall: modal, 3 tiers, annual preselected, trial terms, restore,
/// close always visible. Offering comes from RevenueCat per placement.
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key, required this.placement, this.next});
  final String placement;
  final String? next;

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  late final Placement _placement = PlacementX.parse(widget.placement);
  List<Tile>? _tiles;
  Tile? _selected;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    final a = ref.read(servicesProvider).analytics;
    unawaited(a.log(Events.paywallShown, {'placement': widget.placement}));
    if (_placement == Placement.trialEnd) {
      unawaited(a.log(Events.trialEndPaywallShown));
    }
  }

  Future<void> _load() async {
    try {
      final tiles = await ref
          .read(servicesProvider)
          .purchases
          .tiles(_placement);
      if (!mounted) return;
      setState(() {
        _tiles = tiles;
        // Annual is the preselected default.
        _selected =
            tiles.where((t) => t.period == Period.annual).firstOrNull ??
            tiles.firstOrNull;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Couldn’t load plans — check your connection.');
      }
    }
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(widget.next ?? '/today');
    }
  }

  Future<void> _buy() async {
    final t = _selected;
    if (t == null) return;
    final s = ref.read(servicesProvider);
    setState(() => _busy = true);
    try {
      final r = await s.purchases.purchase(t);
      if (r.cancelled) return;
      ref.read(entitlementProvider.notifier).apply(r.entitlement);
      final hasPhotos = s.local.checkins.any(
        (c) => c.baseline && c.photos.length == 3,
      );
      await s.analytics.log(Events.purchaseCompleted, {
        'product': t.id,
        'placement': widget.placement,
      });
      if (r.entitlement.trial && hasPhotos) {
        await s.analytics.log(Events.trialStartedWithPhotos, {'product': t.id});
      }
      if (_placement == Placement.winback) {
        await s.analytics.log(Events.winbackAccepted);
      }
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showSnack(
        context,
        r.entitlement.trial
            ? 'Trial started — welcome to Pro'
            : 'Welcome to Pro',
      );
      _close();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Purchase failed');
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Purchase failed — you have not been charged.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final s = ref.read(servicesProvider);
    setState(() => _busy = true);
    try {
      final e = await s.purchases.restore();
      ref.read(entitlementProvider.notifier).apply(e);
      await s.analytics.log(Events.restoreCompleted, {'pro': e.pro ? 1 : 0});
      if (!mounted) return;
      showSnack(
        context,
        e.pro ? 'Purchases restored' : 'No active subscription found',
      );
      if (e.pro) _close();
    } catch (_) {
      if (mounted) showSnack(context, 'Restore failed — check your connection');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.read(servicesProvider);
    final needsBaseline =
        _placement == Placement.onboarding &&
        !s.local.checkins.any((c) => c.photos.length == 3);
    final socialProof = s.remoteConfig['social_proof'] ?? '';
    final winbackCode = s.remoteConfig['winback_offer_code'] ?? '';
    final t = _selected;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(20, 48, 20, 24),
              children: [
                const Tag('D7 · Paywall'),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _placement == Placement.winback
                            ? 'Welcome back. '
                            : 'Keep changing. ',
                      ),
                      const TextSpan(
                        text: 'Go Pro.',
                        style: TextStyle(color: Brand.lime),
                      ),
                    ],
                  ),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                for (final f in const [
                  'AI photo reports: waist & body-fat estimates',
                  'Adaptive weekly re-plans',
                  'Aligned timeline + morph',
                  'Weekly nutrition reports · 20 coach messages/mo',
                  '1 future-physique render a month',
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        const Icon(Icons.check, color: Brand.mint, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(f)),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                if (needsBaseline)
                  InfoBanner(
                    icon: Icons.photo_camera_front_outlined,
                    text: 'Your free trial starts with 3 baseline photos.',
                    action: 'Take photos',
                    onAction: () => context.push('/checkin'),
                  ),
                if (_tiles == null && _error == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                for (final tile in _tiles ?? const <Tile>[])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _TileCard(
                      tile: tile,
                      selected: tile == t,
                      onTap: () => setState(() => _selected = tile),
                    ),
                  ),
                if (socialProof.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      socialProof,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Brand.textDim,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Brand.danger),
                    ),
                  ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: t == null || _busy || needsBaseline ? null : _buy,
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Brand.ink,
                          ),
                        )
                      : Text(
                          t?.trialDays != null
                              ? 'Start ${t!.trialDays}-day free trial'
                              : 'Continue',
                        ),
                ),
                const SizedBox(height: 8),
                if (t != null)
                  Text(
                    _terms(t),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Brand.slate,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                if (_placement == Placement.winback && winbackCode.isNotEmpty)
                  TextButton(
                    onPressed: () =>
                        s.purchases.presentStoreRedemption(code: winbackCode),
                    child: Text('Redeem 50% off with code $winbackCode'),
                  ),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : _restore,
                      child: const Text('Restore purchase'),
                    ),
                    const Text('·', style: TextStyle(color: Brand.slate)),
                    TextButton(
                      onPressed: () => context.push('/redeem'),
                      child: const Text('Redeem code'),
                    ),
                  ],
                ),
              ],
            ),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                tooltip: 'Close',
                onPressed: _close,
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _terms(Tile t) {
    final period = switch (t.period) {
      Period.weekly => 'week',
      Period.monthly => 'month',
      Period.annual => 'year',
    };
    final trial = t.trialDays == null
        ? ''
        : '${t.trialDays}-day free trial, then ';
    final intro = t.introPrice == null
        ? ''
        : '${t.introPrice} for the first $period, then ';
    return '$trial$intro${t.price}/$period. Cancel anytime in your store account settings at '
        'least 24 hours before the trial or period ends to avoid being charged.';
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({
    required this.tile,
    required this.selected,
    required this.onTap,
  });
  final Tile tile;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = switch (tile.period) {
      Period.weekly => 'Weekly',
      Period.monthly => 'Monthly',
      Period.annual => 'Annual',
    };
    final per = switch (tile.period) {
      Period.weekly => '/wk',
      Period.monthly => '/mo',
      Period.annual => '/yr',
    };
    return Semantics(
      selected: selected,
      button: true,
      label: '$name plan ${tile.price}$per',
      child: BrandCard(
        onTap: onTap,
        border: selected ? Brand.lime : Brand.track,
        color: selected ? Brand.lime.withValues(alpha: 0.07) : Brand.card,
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? Brand.lime : Brand.slate,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      if (tile.period == Period.annual) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Brand.lime,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'BEST VALUE',
                            style: TextStyle(
                              color: Brand.ink,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    [
                      if (tile.trialDays != null)
                        '${tile.trialDays}-day free trial',
                      if (tile.introPrice != null)
                        '${tile.introPrice} first year',
                      if (tile.perMonth != null) tile.perMonth!,
                    ].join(' · '),
                    style: const TextStyle(color: Brand.textDim, fontSize: 12),
                  ),
                ],
              ),
            ),
            Text(
              '${tile.price}$per',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}
