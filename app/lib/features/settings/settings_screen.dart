import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../data/sync/outbox.dart';
import '../../domain/access.dart';
import '../../domain/models.dart';
import '../../services/analytics.dart';
import '../../services/device_services.dart';
import '../../widgets/common.dart';

/// D6 Settings: profile, reminders, health sync, privacy/biometric,
/// subscription status, sync status, delete account.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _saveProfile(WidgetRef ref, Profile p) =>
      ref.read(repoProvider).saveProfile(p);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.read(servicesProvider);
    final p = ref.watch(profileProvider) ?? Profile();
    final ent = ref.watch(entitlementProvider);
    final tier = ref.watch(tierProvider);
    final ops = ref.watch(outboxProvider).value ?? const <OutboxOp>[];
    final failed = ops.where((o) => o.state == OpState.failed).toList();
    final user = ref.watch(authUserProvider).value;
    final now = ref.watch(clockProvider).now();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Section('Subscription'),
          ListTile(
            leading: Icon(
              tier == Tier.pro ? Icons.workspace_premium : Icons.lock_open,
              color: tier == Tier.pro ? Brand.lime : Brand.slate,
            ),
            title: Text(switch (tier) {
              Tier.pro =>
                ent.trial
                    ? 'Pro · free trial'
                    : (ent.promo ? 'Pro · promo' : 'Pro'),
              Tier.grace => 'Free (grace) — your data is safe',
              Tier.free => 'Free',
            }),
            subtitle: Text(
              [
                if (ent.expiresAt != null && tier == Tier.pro)
                  '${ent.willRenew ? 'Renews' : 'Ends'} ${_date(ent.expiresAt!)}',
                if (ent.billingIssue)
                  'Payment issue — update your payment method',
              ].join(' · '),
            ),
          ),
          if (tier != Tier.pro)
            ListTile(
              leading: const Icon(Icons.bolt, color: Brand.lime),
              title: const Text('See Pro plans'),
              onTap: () => context.push('/paywall?placement=settings'),
            ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Manage or cancel subscription'),
            onTap: () async {
              await s.analytics.log(Events.cancelTap);
              await s.purchases.manageSubscription();
            },
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Restore purchases'),
            onTap: () async {
              final e = await s.purchases.restore();
              ref.read(entitlementProvider.notifier).apply(e);
              if (context.mounted) {
                showSnack(
                  context,
                  e.pro ? 'Restored' : 'No active subscription found',
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.redeem),
            title: const Text('Redeem a code'),
            onTap: () => context.push('/redeem'),
          ),
          _Section('Profile'),
          ListTile(
            title: const Text('Goal'),
            trailing: DropdownButton<Goal>(
              value: p.goal,
              underline: const SizedBox.shrink(),
              items: [
                for (final g in Goal.values)
                  DropdownMenuItem(value: g, child: Text(g.label)),
              ],
              onChanged: (g) => _saveProfile(ref, p.copyWith(goal: g)),
            ),
          ),
          ListTile(
            title: const Text('Level'),
            trailing: DropdownButton<Level>(
              value: p.level,
              underline: const SizedBox.shrink(),
              items: [
                for (final l in Level.values)
                  DropdownMenuItem(
                    value: l,
                    child: Text(l.name[0].toUpperCase() + l.name.substring(1)),
                  ),
              ],
              onChanged: (l) => _saveProfile(ref, p.copyWith(level: l)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Equipment', style: TextStyle(color: Brand.textDim)),
                const SizedBox(height: 6),
                ChoiceChips<String>(
                  options: equipmentOptions,
                  selected: p.equipment.toSet(),
                  onTap: (e) {
                    final set = p.equipment.toSet();
                    set.contains(e) ? set.remove(e) : set.add(e);
                    _saveProfile(
                      ref,
                      p.copyWith(
                        equipment: set.isEmpty ? ['bodyweight'] : set.toList(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                const Text('Injuries', style: TextStyle(color: Brand.textDim)),
                const SizedBox(height: 6),
                ChoiceChips<String>(
                  options: injuryOptions,
                  selected: p.injuries.toSet(),
                  onTap: (i) {
                    final set = p.injuries.toSet();
                    set.contains(i) ? set.remove(i) : set.add(i);
                    _saveProfile(ref, p.copyWith(injuries: set.toList()));
                  },
                ),
                Stepper2(
                  label: 'Days per week',
                  value: p.daysPerWeek.toDouble(),
                  min: 2,
                  max: 6,
                  onChanged: (v) =>
                      _saveProfile(ref, p.copyWith(daysPerWeek: v.round())),
                ),
                Stepper2(
                  label: 'Minutes',
                  value: p.mins.toDouble(),
                  min: 20,
                  max: 90,
                  step: 5,
                  unit: ' min',
                  onChanged: (v) =>
                      _saveProfile(ref, p.copyWith(mins: v.round())),
                ),
                const Text(
                  'Changes apply at your next weekly re-plan.',
                  style: TextStyle(color: Brand.slate, fontSize: 12),
                ),
              ],
            ),
          ),
          _Section('Reminders'),
          ListTile(
            leading: const Icon(Icons.alarm),
            title: const Text('Workout reminder'),
            trailing: Text('${p.reminderHour}:00'),
            onTap: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: p.reminderHour, minute: 0),
              );
              if (t == null) return;
              await _saveProfile(ref, p.copyWith(reminderHour: t.hour));
              final plan = ref.read(planProvider);
              await s.notifications.requestPermission();
              await s.notifications.scheduleWorkoutReminders(
                hour: t.hour,
                weekdays: plan == null
                    ? [1, 3, 5]
                    : {
                        for (final sess in plan.mesocycle.weeks.first.sessions)
                          (plan.startDate.weekday - 1 + sess.dayIndex) % 7 + 1,
                      }.toList(),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Sunday check-in reminder'),
            trailing: Text('${p.checkinReminderHour}:00'),
            onTap: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: p.checkinReminderHour, minute: 0),
              );
              if (t == null) return;
              await _saveProfile(ref, p.copyWith(checkinReminderHour: t.hour));
              if (user != null) {
                await ref.read(repoProvider).outbox.enqueue('doc.upsert', {
                  'collection': '',
                  'id': 'me',
                  'data': {
                    'checkin_reminder_slot': checkinReminderSlot(
                      t.hour,
                      DateTime.now().timeZoneOffset,
                    ),
                  },
                });
              }
            },
          ),
          _Section('Health & privacy'),
          SwitchListTile(
            secondary: const Icon(Icons.monitor_heart_outlined),
            title: const Text('Health sync (read weight)'),
            subtitle: const Text('Apple Health / Health Connect — read-only'),
            value: p.healthSync,
            onChanged: (v) async {
              if (v && !await s.health.requestAccess()) {
                if (context.mounted) {
                  showSnack(context, 'Health access not granted');
                }
                return;
              }
              await _saveProfile(ref, p.copyWith(healthSync: v));
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.face_retouching_off),
            title: const Text('Blur my face in photos'),
            value: p.faceBlur,
            onChanged: (v) => _saveProfile(ref, p.copyWith(faceBlur: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Biometric lock'),
            subtitle: const Text('Face ID / fingerprint to open the app'),
            value: p.biometricLock,
            onChanged: (v) async {
              if (v &&
                  !(await s.biometric.available() &&
                      await s.biometric.unlock())) {
                if (context.mounted) {
                  showSnack(context, 'Biometrics unavailable on this device');
                }
                return;
              }
              await _saveProfile(ref, p.copyWith(biometricLock: v));
            },
          ),
          _Section('Sync'),
          ListTile(
            leading: Icon(
              failed.isEmpty ? Icons.cloud_done_outlined : Icons.sync_problem,
              color: failed.isEmpty ? Brand.mint : Brand.danger,
            ),
            title: Text(
              failed.isEmpty
                  ? (ops.isEmpty
                        ? 'All changes synced'
                        : '${ops.length} change(s) waiting to sync')
                  : '${failed.length} change(s) failed to sync',
            ),
            subtitle: failed.isEmpty ? null : Text(failed.first.error ?? ''),
            trailing: failed.isEmpty
                ? null
                : TextButton(
                    onPressed: () => ref.read(repoProvider).retryFailed(),
                    child: const Text('Retry'),
                  ),
          ),
          _Section('Account'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(user?.email ?? 'Signed in'),
            subtitle: Text(
              'Member since ${p.createdAt == null ? '—' : _date(p.createdAt!)}',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              await s.purchases.logOut();
              await s.auth.signOut();
              await s.local.clearAll();
              if (context.mounted) context.go('/onboarding');
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Brand.danger),
            title: const Text(
              'Delete account & all data',
              style: TextStyle(color: Brand.danger),
            ),
            subtitle: const Text(
              'Photos, logs and profile are purged within 24 hours.',
            ),
            onTap: () => _confirmDelete(context, ref),
          ),
          if (!kReleaseMode)
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Debug tools'),
              onTap: () => context.push('/debug'),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Forme AI · ${_date(now)}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Brand.slate, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete everything?'),
        content: const Text(
          'This permanently deletes your account, progress photos, logs and '
          'plan. Subscriptions are billed by the App Store / Google Play — cancel there too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Brand.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final s = ref.read(servicesProvider);
    try {
      await s.remote.deleteAccount();
    } catch (_) {
      if (context.mounted) {
        showSnack(
          context,
          'Needs connection to delete your account — nothing was deleted.',
        );
      }
      return;
    }
    await s.purchases.logOut();
    await s.auth.signOut();
    await s.local.clearAll();
    if (context.mounted) context.go('/onboarding');
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
    child: Tag(title),
  );
}
