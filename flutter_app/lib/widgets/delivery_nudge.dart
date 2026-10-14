// "Buyers can't reach you" - the reminder that BROKA can't notify this phone
// (services/delivery_access.dart), where it costs someone something:
//
//   * Home and the Inbox: a glowing card while notifications or background
//     running are off, naming what was missed ("3 unread messages you
//     weren't told about") when the inbox knows. "Later" puts it away for
//     three days, not for good.
//   * A listing just posted (DeliveryNudge.listingLive): the moment a seller
//     most wants to hear from buyers.
//
// "Turn on" walks through whatever is off, notifications first, and the
// card checks again when the person comes back from the phone's settings,
// so it goes the moment it's fixed. Nothing shows when all is well, while
// it can't be told, or while snoozed.

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/delivery_access.dart';
import '../services/global_poller_service.dart';

enum DeliveryNudgePlace { feed, inbox, listingLive }

class DeliveryNudge extends StatefulWidget {
  const DeliveryNudge({
    super.key,
    this.place = DeliveryNudgePlace.feed,
    this.margin = const EdgeInsets.fromLTRB(16, 4, 16, 12),
    this.access,
  });

  /// After a listing is posted: no snooze button (it shows once, there),
  /// and it speaks to the seller.
  const DeliveryNudge.listingLive({super.key, this.margin = const EdgeInsets.only(top: 18), this.access})
      : place = DeliveryNudgePlace.listingLive;

  final DeliveryNudgePlace place;
  final EdgeInsetsGeometry margin;

  /// Defaults to DeliveryAccess.instance.
  final DeliveryAccess? access;

  @override
  State<DeliveryNudge> createState() => _DeliveryNudgeState();
}

class _DeliveryNudgeState extends State<DeliveryNudge> {
  DeliveryAccess get _access => widget.access ?? DeliveryAccess.instance;

  DeliveryState? _state;
  bool _snoozed = true;
  bool _fixing = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from the phone's settings: look again.
    _lifecycle = AppLifecycleListener(onResume: _check);
    _check();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final snoozed = widget.place != DeliveryNudgePlace.listingLive && await _access.isSnoozed();
    final state = snoozed ? null : await _access.check();
    if (!mounted) return;
    setState(() {
      _snoozed = snoozed;
      _state = state;
    });
  }

  Future<void> _turnOn() async {
    final state = _state;
    if (state == null || _fixing) return;
    setState(() => _fixing = true);
    await _access.fix(state);
    if (!mounted) return;
    setState(() => _fixing = false);
    await _check();
  }

  Future<void> _later() async {
    await _access.snooze();
    if (mounted) setState(() => _snoozed = true);
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (_snoozed || state == null || state.allGood) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: GlobalPollerService.instance.unreadTotal,
      builder: (context, unread, _) => _card(state, unread),
    );
  }

  (String, String) _words(DeliveryState s, int unread) {
    final seller = widget.place == DeliveryNudgePlace.listingLive;
    if (!s.notificationsAllowed) {
      final title = seller ? "Hear from buyers the moment they write" : 'Notifications are off';
      final missed = unread > 0 && !seller
          ? 'You have $unread unread ${unread == 1 ? 'message' : 'messages'} BROKA couldn\'t tell you about. '
          : '';
      final body = seller
          ? "Buyers will message, make offers and call about this listing - but with notifications off, "
              "you'll only know when you open BROKA. The first seller to answer usually gets the sale."
          : "${missed}Messages, offers and calls only reach you while BROKA is open. "
              'Turn notifications on so you never miss a buyer or a seller.';
      return (title, body);
    }
    return (
      'Your phone may be holding BROKA back',
      'Battery saving can stop calls ringing and messages arriving while BROKA is closed. '
          'Let it run in the background - it only wakes when someone calls or writes. '
          'On Tecno, Infinix, Xiaomi and Oppo phones, also turn on Autostart for BROKA '
          'in Settings › Apps.',
    );
  }

  Widget _card(DeliveryState state, int unread) {
    final (title, body) = _words(state, unread);
    final off = !state.notificationsAllowed;
    final accent = off ? BrokaColors.danger : BrokaColors.gold;
    return Container(
      key: const Key('delivery-nudge'),
      margin: widget.margin,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withOpacity(0.20), BrokaColors.bgCard.withOpacity(0.95)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withOpacity(0.7), width: 1.2),
        boxShadow: [BoxShadow(color: accent.withOpacity(0.22), blurRadius: 18)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withOpacity(0.18)),
            child: Icon(off ? Icons.notifications_off_rounded : Icons.battery_alert_rounded,
                color: accent, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 14.5, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(body, style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 12.5, height: 1.4)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
          if (widget.place != DeliveryNudgePlace.listingLive)
            TextButton(
              key: const Key('delivery-nudge-later'),
              onPressed: _fixing ? null : _later,
              child: const Text('Later', style: TextStyle(color: BrokaColors.textMid)),
            ),
          FilledButton.icon(
            key: const Key('delivery-nudge-turn-on'),
            onPressed: _fixing ? null : _turnOn,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: Icon(off ? Icons.notifications_active_rounded : Icons.bolt_rounded, size: 17),
            label: Text(off ? 'Turn on' : 'Allow',
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
      ]),
    );
  }
}
