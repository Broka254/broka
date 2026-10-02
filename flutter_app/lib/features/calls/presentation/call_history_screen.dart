// Calls - every voice and video call with a buyer or seller, newest first
// (2026-10-02). Calls were only ever recorded as cards inside each chat, so
// finding a missed call meant opening every conversation.
//
// On Home's visual system, like the Inbox it opens from: the constellation,
// the shared collapsing header, and cards like Home's. A call opens its
// chat; the button at its end calls back.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../widgets/chat_parts.dart' show kChatGradient;
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../../zeno_assistant/domain/zeno_action.dart';
import '../../zeno_assistant/zeno_action_runner.dart';
import '../data/call_history_repository.dart';
import '../domain/call_record.dart';

class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key, this.animateBackground = true, this.repository});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;
  final CallHistoryRepository? repository;

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  CallHistoryRepository get _repo => widget.repository ?? callHistoryRepository;

  final List<CallRecord> _calls = [];
  String? _nextBefore;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  bool _missedOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = _calls.isEmpty; _error = null; });
    final result = await _repo.page();
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _calls..clear()..addAll(data.calls);
          _nextBefore = data.nextBefore;
        case Failure(:final message):
          // Keep what is on screen; only an empty screen shows the error.
          if (_calls.isEmpty) _error = _friendly(message);
      }
    });
  }

  Future<void> _loadMore() async {
    final before = _nextBefore;
    if (before == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    final result = await _repo.page(before: before);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (result case Success(:final data)) {
        final have = {for (final c in _calls) c.id};
        _calls.addAll(data.calls.where((c) => !have.contains(c.id)));
        _nextBefore = data.nextBefore;
      }
    });
  }

  String _friendly(String message) {
    if (message.contains('SocketException') || message.contains('Failed host lookup') ||
        message.contains('Connection')) {
      return "No internet connection.\nPull down to try again once you're back online.";
    }
    if (message.contains('TimeoutException')) return 'The connection timed out.\nPull down to try again.';
    return message.replaceFirst('Exception: ', '');
  }

  int get _missedCount => _calls.where((c) => c.missed).length;

  List<CallRecord> get _shown => _missedOnly ? _calls.where((c) => c.missed).toList() : _calls;

  /// The chat the call happened in - where its card is.
  void _openChat(CallRecord c) {
    Navigator.pushNamed(context, '/direct-chat', arguments: {
      'listingId': c.listingId,
      'role':      c.myRole,
      'buyer_id':  c.buyerId,
    });
  }

  /// The same way every call in the app is placed (ZenoActionRunner.callOn:
  /// /calls/initiate, then the call screen) - one path that rings a phone.
  Future<void> _callBack(CallRecord c) async {
    await ZenoActionRunner.callOn(
      Navigator.of(context),
      ZenoContact(
        listingId:   c.listingId,
        listingName: c.listingName,
        peerId:      c.peer.id,
        peerName:    c.peerDisplayName,
        role:        c.myRole,
        buyerId:     c.buyerId,
      ),
      video: c.isVideo,
    );
    // The call just placed is in the history once it's over.
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final missed = _missedCount;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: BrokaColors.gold,
            backgroundColor: BrokaColors.bgCard,
            displacement: 72,
            onRefresh: _load,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 400) _loadMore();
                return false;
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: CollapsingScreenHeader(
                      title: 'Calls',
                      emoji: '📞',
                      gradient: kChatGradient,
                      onBack: () => Navigator.maybePop(context),
                      narrow: media.size.width < 360,
                      textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                      trailing: missed > 0 ? _MissedPill(missed) : null,
                      trailingKey: missed,
                    ),
                  ),
                  ..._body(media),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(MediaQueryData media) {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator(
              color: BrokaColors.gold, strokeWidth: 1.5)),
        ),
      ];
    }
    if (_error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: BrokaEmptyState(
            emoji: '📡',
            gradient: kChatGradient,
            headline: "Couldn't load your calls",
            body: _error!,
            action: GradientButton(
              onPressed: _load,
              colors: kChatGradient,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('Retry', style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          )),
        ),
      ];
    }
    if (_calls.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: BrokaEmptyState(
            emoji: '📞',
            gradient: kChatGradient,
            headline: 'No calls yet',
            body: 'Voice and video calls with buyers and sellers show up here. '
                'Start one from a chat with the call button.',
          )),
        ),
      ];
    }

    final shown = _shown;
    final rows = <Widget>[];
    String? day;
    for (final c in shown) {
      final label = _dayLabel(c.at);
      if (label != day) {
        day = label;
        rows.add(_DayLabel(label));
      }
      rows.add(_CallRow(
        call: c,
        onTap: () => _openChat(c),
        onCallBack: () => _callBack(c),
      ));
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: _FilterPills(
            missedOnly: _missedOnly,
            missedCount: _missedCount,
            onChanged: (v) => setState(() => _missedOnly = v),
          ),
        ),
      ),
      if (shown.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: BrokaEmptyState(
            emoji: '✅',
            gradient: kChatGradient,
            headline: 'No missed calls',
            body: "You've answered every call that came in.",
          )),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + media.padding.bottom),
          sliver: SliverList(delegate: SliverChildListDelegate([
            ...rows,
            if (_nextBefore != null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(color: BrokaColors.gold, strokeWidth: 1.5))),
              ),
          ])),
        ),
    ];
  }
}

/// "Today", "Yesterday", a weekday this week, else "12 Sep" (with the year
/// once it isn't this year's).
String _dayLabel(DateTime? at, {DateTime? now}) {
  if (at == null) return 'Earlier';
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(at);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return _weekdays[day.weekday - 1];
  final base = '${day.day} ${_months[day.month - 1]}';
  return day.year == today.year ? base : '$base ${day.year}';
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _clock(DateTime? at) {
  if (at == null) return '';
  return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
    child: Text(label.toUpperCase(),
        style: const TextStyle(color: BrokaColors.textMid, fontSize: 11,
            fontWeight: FontWeight.w700, letterSpacing: 1.3)),
  );
}

/// "All" / "Missed" - the Seller Dashboard's pill switcher, small.
class _FilterPills extends StatelessWidget {
  const _FilterPills({required this.missedOnly, required this.missedCount, required this.onChanged});

  final bool missedOnly;
  final int missedCount;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.86),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(children: [
      _pill('All', !missedOnly, () => onChanged(false)),
      _pill(missedCount > 0 ? 'Missed ($missedCount)' : 'Missed', missedOnly, () => onChanged(true)),
    ]),
  );

  Widget _pill(String label, bool on, VoidCallback onTap) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          gradient: on ? const LinearGradient(colors: kChatGradient) : null,
          borderRadius: BorderRadius.circular(12),
          boxShadow: on
              ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.25), blurRadius: 10)]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(
            color: on ? Colors.white : BrokaColors.textMid,
            fontSize: 13, fontWeight: FontWeight.w700)),
      ),
    ),
  );
}

/// "2 missed" in the header, in the danger red the Inbox's badges use.
class _MissedPill extends StatelessWidget {
  const _MissedPill(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$count missed',
    excludeSemantics: true,
    child: Container(
      height: CollapsingScreenHeader.control,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BrokaColors.danger.withOpacity(0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.danger.withOpacity(0.6)),
      ),
      child: Text('$count missed', style: const TextStyle(
          color: BrokaColors.danger, fontSize: 12.5, fontWeight: FontWeight.w800)),
    ),
  );
}

class _CallRow extends StatelessWidget {
  const _CallRow({required this.call, required this.onTap, required this.onCallBack});

  final CallRecord call;
  final VoidCallback onTap;
  final VoidCallback onCallBack;

  @override
  Widget build(BuildContext context) {
    final c = call;
    final name = c.peerDisplayName;
    final accent = c.missed
        ? BrokaColors.danger
        : (c.isOutgoing ? BrokaColors.neonBlue : BrokaColors.neonGreen);
    final directionIcon = c.missed
        ? Icons.call_missed_rounded
        : (c.isOutgoing ? Icons.call_made_rounded : Icons.call_received_rounded);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: c.missed ? BrokaColors.danger.withOpacity(0.45) : BrokaColors.border,
          width: c.missed ? 1.3 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
            child: Row(children: [
              _Avatar(peer: c.peer, name: name),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: c.missed ? BrokaColors.danger : BrokaColors.textHigh,
                          fontSize: 14.5, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 6),
                  Text(_clock(c.at), style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 11.5)),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  Icon(directionIcon, size: 14, color: accent),
                  const SizedBox(width: 4),
                  Icon(c.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      size: 12, color: BrokaColors.textMid),
                  const SizedBox(width: 4),
                  Flexible(child: Text(
                    '${c.isOutgoing ? 'Outgoing' : 'Incoming'} · ${c.summary}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.missed ? BrokaColors.danger : BrokaColors.textMid,
                        fontSize: 12, fontWeight: c.missed ? FontWeight.w600 : FontWeight.w400),
                  )),
                ]),
                const SizedBox(height: 3),
                Text(
                  c.listingName.isEmpty ? c.peerRoleLabel : '${c.peerRoleLabel} · ${c.listingName}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
                ),
              ])),
              const SizedBox(width: 4),
              _CallBackButton(
                  key: Key('call-back-${c.id}'), video: c.isVideo, name: name, onTap: onCallBack),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.peer, required this.name});

  final CallPeer peer;
  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    final initials = Center(child: Text(initial, style: const TextStyle(
        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17)));
    Widget face = initials;
    final photo = peer.photo;
    if (photo != null && photo.isNotEmpty) {
      try {
        face = Image.memory(base64Decode(photo), fit: BoxFit.cover,
            gaplessPlayback: true, errorBuilder: (_, __, ___) => initials);
      } catch (_) {
        // Malformed base64: decode throws before errorBuilder can help.
      }
    }
    return Stack(children: [
      Container(
        width: 46, height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: kChatGradient),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45), width: 1.2),
        ),
        child: ClipOval(child: SizedBox.expand(child: face)),
      ),
      if (peer.isOnline)
        Positioned(right: 0, bottom: 0, child: Container(
          width: 12, height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: BrokaColors.neonGreen,
            border: Border.all(color: BrokaColors.bgCard, width: 2),
          ),
        )),
    ]);
  }
}

class _CallBackButton extends StatelessWidget {
  const _CallBackButton({super.key, required this.video, required this.name, required this.onTap});

  final bool video;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${video ? 'Video call' : 'Call'} $name',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: BrokaColors.neonGreen.withOpacity(0.14),
            border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.55)),
          ),
          child: Icon(video ? Icons.videocam_rounded : Icons.call_rounded,
              size: 20, color: BrokaColors.neonGreen),
        ),
      ),
    ),
  );
}
