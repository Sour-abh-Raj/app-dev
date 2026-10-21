import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/sync/outbox.dart';
import '../../domain/access.dart';
import '../../widgets/common.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        children: [
          const _StatusBanners(),
          Expanded(child: shell),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: shell.currentIndex,
      onDestinationSelected: (i) =>
          shell.goBranch(i, initialLocation: i == shell.currentIndex),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Today'),
        NavigationDestination(icon: Icon(Icons.restaurant), label: 'Eat'),
        NavigationDestination(icon: Icon(Icons.show_chart), label: 'Progress'),
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          label: 'Coach',
        ),
      ],
    ),
  );
}

/// Offline, billing-issue, grace-mode and sync-failure banners.
class _StatusBanners extends ConsumerWidget {
  const _StatusBanners();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(onlineProvider).value ?? true;
    final ent = ref.watch(entitlementProvider);
    final tier = ref.watch(tierProvider);
    final winback = ref.watch(winbackEligibleProvider);
    final ops = ref.watch(outboxProvider).value ?? const [];
    final failed = ops.where((o) => o.state == OpState.failed).length;
    final pending = ops.where((o) => o.state == OpState.pending).length;

    final banners = <Widget>[
      if (!online)
        InfoBanner(
          icon: Icons.cloud_off,
          text: pending > 0
              ? 'Offline — $pending change${pending == 1 ? '' : 's'} saved, will sync'
              : 'Offline — logging still works',
        ),
      if (ent.billingIssue)
        InfoBanner(
          icon: Icons.credit_card,
          text: 'Payment didn’t go through. Fix it to keep Pro.',
          action: 'Fix payment',
          onAction: () =>
              ref.read(servicesProvider).purchases.manageSubscription(),
        ),
      if (tier == Tier.grace)
        InfoBanner(
          icon: Icons.lock_open,
          text: 'Your logs, photos and streak are safe. AI is paused.',
          action: winback ? '50% off' : 'Go Pro',
          onAction: () => context.push(
            '/paywall?placement=${winback ? 'winback' : 'settings'}',
          ),
        ),
      if (failed > 0)
        InfoBanner(
          icon: Icons.sync_problem,
          color: Brand.danger.withValues(alpha: 0.15),
          text: '$failed change${failed == 1 ? '' : 's'} couldn’t sync',
          action: 'Retry',
          onAction: () => ref.read(repoProvider).retryFailed(),
        ),
    ];
    if (banners.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(children: banners),
    );
  }
}
