import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../domain/validators.dart';
import '../../services/analytics.dart';
import '../../widgets/common.dart';

/// Redeem: store-native offer/promo codes (per store — no cross-platform code
/// exists) and server-side staff/test codes (/v1/promo/redeem).
class RedeemScreen extends ConsumerStatefulWidget {
  const RedeemScreen({super.key});

  @override
  ConsumerState<RedeemScreen> createState() => _RedeemScreenState();
}

class _RedeemScreenState extends ConsumerState<RedeemScreen> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _msg;

  static String _explain(String code) => switch (code) {
    'not_found' => 'That code isn’t valid.',
    'expired' => 'That code has expired.',
    'revoked' => 'That code is no longer active.',
    'exhausted' => 'That code has been fully used.',
    'already_redeemed' => 'You’ve already redeemed this code.',
    'rate_limited' => 'Too many attempts — try again in an hour.',
    _ => 'Couldn’t redeem right now.',
  };

  Future<void> _redeemStaff() async {
    final code = Validators.normalizePromo(_ctrl.text);
    if (code == null) {
      setState(() => _msg = _explain('not_found'));
      return;
    }
    final s = ref.read(servicesProvider);
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final until = await s.api.redeemPromo(code);
      await s.analytics.log(Events.promoRedeemed);
      try {
        ref
            .read(entitlementProvider.notifier)
            .apply(await s.purchases.refresh());
      } catch (_) {}
      setState(
        () => _msg =
            'Pro unlocked until ${until.toLocal().toString().substring(0, 10)} 🎉',
      );
    } on PermanentError catch (e) {
      setState(() => _msg = _explain(e.code ?? ''));
    } on TransientError catch (e) {
      setState(
        () => _msg = e.message == 'rate_limited'
            ? _explain('rate_limited')
            : 'Needs connection — try again when online.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.read(servicesProvider);
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return Scaffold(
      appBar: AppBar(title: const Text('Redeem a code')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            ios ? 'App Store offer code' : 'Google Play promo code',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            ios
                ? 'Offer codes (like a launch code) are redeemed securely by Apple.'
                : 'Play promo codes are redeemed in the Play Store and unlock a free trial.',
            style: const TextStyle(color: Brand.textDim),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => s.purchases.presentStoreRedemption(),
            icon: const Icon(Icons.open_in_new),
            label: Text(ios ? 'Redeem in App Store' : 'Redeem in Google Play'),
          ),
          const Divider(height: 40),
          Text(
            'Team or tester code',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'Codes from the Forme team.',
            style: TextStyle(color: Brand.textDim),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(hintText: 'CODE'),
            onSubmitted: (_) => _redeemStaff(),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _redeemStaff,
            child: _busy
                ? const CircularProgressIndicator()
                : const Text('Redeem'),
          ),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: InfoBanner(icon: Icons.info_outline, text: _msg!),
            ),
        ],
      ),
    );
  }
}
