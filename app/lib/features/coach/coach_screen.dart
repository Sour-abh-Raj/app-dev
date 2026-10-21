import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/clock.dart';
import '../../core/errors.dart';
import '../../domain/models.dart';
import '../../domain/training.dart';
import '../../domain/validators.dart';
import '../../services/analytics.dart';
import '../../widgets/common.dart';

/// Messages that count against the allowance (successful, unflagged replies).
int chatUsed(
  List<ChatMessage> chat, {
  required bool monthly,
  required DateTime now,
}) => chat
    .where(
      (m) =>
          m.role == 'assistant' &&
          !m.flagged &&
          (!monthly || (m.ts.year == now.year && m.ts.month == now.month)),
    )
    .length;

/// T4 Coach: chat + suggestion chips, capped (5 total free, 20/month Pro).
class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key});

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  bool _capped = false;
  String? _error;
  List<String> _suggestions = const [
    'Swap an exercise',
    '20-min catch-up?',
    'Protein ideas',
    'Why this plan?',
  ];

  Map<String, dynamic> _capsule() {
    final p = ref.read(profileProvider);
    final plan = ref.read(planProvider);
    final now = ref.read(clockProvider).now();
    final ws = ref.read(workoutsProvider);
    final last = ref
        .read(checkinsProvider)
        .where((c) => c.report != null)
        .lastOrNull;
    int? week;
    int? pct;
    if (plan != null) {
      week = positionOf(plan, now).week;
      final a = adherence(plan, ws, week);
      pct = a.planned == 0 ? null : (a.completed * 100 ~/ a.planned);
    }
    return {
      'name': (p?.name ?? '').split(' ').first,
      'goal': ?p?.goal.wire,
      'level': ?p?.level.name,
      'week_index': ?week,
      'adherence_pct': ?pct,
      'injuries': p?.injuries ?? const <String>[],
      'last_report_summary': last?.report?.summary ?? '',
    };
  }

  Future<void> _send(String text) async {
    if (Validators.chatMessage(text) != null || _sending) return;
    _ctrl.clear();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final reply = await ref.read(repoProvider).chat(text, _capsule());
      if (reply.suggestions.isNotEmpty) _suggestions = reply.suggestions;
    } on CapReachedError catch (e) {
      _capped = true;
      await ref.read(servicesProvider).analytics.log(Events.capHit(e.cap));
    } on OfflineError {
      _error =
          'Needs connection — your message is saved. Tap retry when online.';
    } on AppError {
      _error = 'Coach is busy right now. Try again in a moment.';
    } finally {
      if (mounted) setState(() => _sending = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final access = ref.watch(accessProvider);
    final now = ref.watch(clockProvider).now();
    final used = chatUsed(
      chat,
      monthly: access.chatAllowanceIsMonthly,
      now: now,
    );
    final left = (access.chatAllowance - used).clamp(0, 99);
    final capped = _capped || left == 0;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Expanded(child: Tag('T4 · Coach')),
              Text(
                access.chatAllowanceIsMonthly
                    ? '$left of ${access.chatAllowance} left this month'
                    : '$left of ${access.chatAllowance} free messages left',
                style: const TextStyle(color: Brand.slate, fontSize: 12),
              ),
            ],
          ),
        ),
        Expanded(
          child: chat.isEmpty
              ? EmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'Your coach knows your plan',
                  body: 'Ask about form, swaps, food or motivation. Not medical advice.',
                  cta: 'Ask: “Why this plan?”',
                  onCta: () => _send('Why this plan?'),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount:
                      chat.length + (capped ? 1 : 0) + (_error != null ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i < chat.length) return _Bubble(msg: chat[i]);
                    if (_error != null && i == chat.length) {
                      return InfoBanner(
                        icon: Icons.cloud_off,
                        text: _error!,
                        action: 'Retry',
                        onAction: () {
                          final lastUser = chat.lastWhere(
                            (m) => m.role == 'user',
                          );
                          _send(lastUser.content);
                        },
                      );
                    }
                    return UpsellCard(
                      title: access.pro
                          ? 'Monthly messages used'
                          : 'Free messages used',
                      body: access.pro
                          ? 'Your coach allowance resets next month.'
                          : 'Pro includes 20 coach messages a month, plus AI reports and adaptive plans.',
                      placement: 'cap_chat',
                    );
                  },
                ),
        ),
        if (_sending) const LinearProgressIndicator(minHeight: 2),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final s in _suggestions)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    label: Text(s),
                    onPressed: capped ? null : () => _send(s),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  enabled: !capped,
                  maxLength: 2000,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: capped ? 'Allowance used' : 'Message your coach',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Send',
                onPressed: capped || _sending ? null : () => _send(_ctrl.text),
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg});
  final ChatMessage msg;

  @override
  Widget build(BuildContext context) {
    final mine = msg.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: mine ? Brand.chip : Brand.card2,
          borderRadius: BorderRadius.circular(16),
          border: msg.flagged
              ? Border.all(color: Brand.mint.withValues(alpha: 0.5))
              : null,
        ),
        child: Text(msg.content, style: const TextStyle(height: 1.4)),
      ),
    );
  }
}
