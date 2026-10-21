import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/clock.dart';
import '../../domain/access.dart';
import '../../services/purchases_service.dart';
import '../../widgets/common.dart';

/// O11 debug-only time controls. The route is not registered in release
/// builds and every action is a no-op under kReleaseMode.
class DebugScreen extends ConsumerWidget {
  const DebugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kReleaseMode) return const SizedBox.shrink();
    final clock = ref.watch(clockProvider);
    final flags = ref.watch(debugFlagsProvider);
    final s = ref.read(servicesProvider);
    final days = clock.offset.inHours / 24;
    return Scaffold(
      appBar: AppBar(title: const Text('Debug tools')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Clock offset: ${days.toStringAsFixed(1)} days'),
          Text('Now: ${clock.now()}'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              ref.read(clockProvider.notifier).advance(const Duration(days: 7));
              context.push('/checkin');
            },
            child: const Text('Simulate day-7 check-in (+7 days)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => ref
                .read(clockProvider.notifier)
                .advance(const Duration(days: 1)),
            child: const Text('+1 day'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => ref.read(clockProvider.notifier).reset(),
            child: const Text('Reset clock'),
          ),
          const Divider(height: 32),
          SwitchListTile(
            title: const Text('Simulate trial expiry (grace mode + winback)'),
            value: flags.simulateExpired,
            onChanged: (v) {
              ref.read(debugFlagsProvider.notifier).simulateExpiry(v);
              if (v) context.push('/paywall?placement=trial_end');
            },
          ),
          if (s.purchases is FakePurchasesService) ...[
            OutlinedButton(
              onPressed: () => (s.purchases as FakePurchasesService).set(
                Entitlement(
                  pro: true,
                  trial: true,
                  everSubscribed: true,
                  willRenew: true,
                  expiresAt: clock.now().add(const Duration(days: 2)),
                  fetchedAt: clock.now(),
                ),
              ),
              child: const Text('Fake: trial with 2 days left'),
            ),
            OutlinedButton(
              onPressed: () => (s.purchases as FakePurchasesService).set(
                Entitlement(
                  everSubscribed: true,
                  winbackUntil: clock.now().add(const Duration(days: 14)),
                  fetchedAt: clock.now(),
                ),
              ),
              child: const Text('Fake: expired (winback eligible)'),
            ),
          ],
          const Divider(height: 32),
          Text(
            'Outbox: ${s.outbox.pendingCount} pending, ${s.outbox.failed().length} failed',
          ),
          OutlinedButton(
            onPressed: () => s.sync.drain(),
            child: const Text('Drain outbox now'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () {
              throw StateError('Crashlytics test (debug only)');
            },
            child: const Text('Throw test error'),
          ),
          const SizedBox(height: 8),
          Text('Mode: ${s.demo ? 'offline demo' : 'live backends'}'),
          const PrivacyNote(
            text: 'This screen is compiled out of release builds.',
          ),
        ],
      ),
    );
  }
}
