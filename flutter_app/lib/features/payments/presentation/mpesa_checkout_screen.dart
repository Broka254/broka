// BROKA - paying with M-Pesa: the number the prompt goes to, what is being
// paid for, and Pay. Then it waits for M-Pesa to confirm.
//
// The number is the first thing on the screen, filled in with the
// account's own and editable in place. It used to sit at the bottom of the
// plan or months form, below everything else, where people paid from the
// wrong line without noticing which one it was.
//
// Pops `true` once paid.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../utils/price_format.dart';
import '../../listing_fee/data/listing_fee_repository.dart';
import '../domain/checkout.dart';
import 'checkout_widgets.dart';

enum _Stage { ready, prompting, waiting, slow, paid }

class MpesaCheckoutScreen extends StatefulWidget {
  const MpesaCheckoutScreen({
    super.key,
    required this.order,
    required this.charge,
    required this.success,
    this.popOnPaid = false,
    this.initialPhone,
    this.pollEvery = const Duration(seconds: 3),
    this.giveUpAfter = const Duration(seconds: 150),
  });

  final CheckoutOrder order;
  final MpesaCharge charge;
  final CheckoutSuccess success;

  /// Close as soon as M-Pesa confirms (see PaymentMethodScreen.popOnPaid).
  final bool popOnPaid;

  /// The number to start with; the signed-in account's when null.
  final String? initialPhone;
  final Duration pollEvery;

  /// How long to watch before saying M-Pesa is slow. The payment still
  /// lands when M-Pesa confirms; the person just stops watching.
  final Duration giveUpAfter;

  @override
  State<MpesaCheckoutScreen> createState() => _MpesaCheckoutScreenState();
}

class _MpesaCheckoutScreenState extends State<MpesaCheckoutScreen> {
  _Stage _stage = _Stage.ready;
  final _phone = TextEditingController();
  final _phoneFocus = FocusNode();
  String? _error;
  ChargeStarted? _started;
  ChargeProgress? _progress;

  // Kept across a timed-out attempt, so pressing Pay again re-sends the
  // same request - and the server answers with the prompt it already sent
  // rather than prompting the phone twice. A changed number starts afresh.
  String? _attemptKey;
  Timer? _poll;
  DateTime? _waitingSince;
  // A status request still out: the next tick waits for it rather than
  // stacking a second one on a slow connection.
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _phone.text = widget.initialPhone ?? ApiService.currentUserPhone ?? '';
  }

  @override
  void dispose() {
    _poll?.cancel();
    _phone.dispose();
    _phoneFocus.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    if (_stage == _Stage.prompting) return;
    final digits = _phone.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 9) {
      setState(() => _error = 'Enter the Safaricom number to pay from, e.g. 0712 345 678.');
      _phoneFocus.requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();
    _attemptKey ??= ListingFeeRepository.newAttemptKey();
    setState(() {
      _stage = _Stage.prompting;
      _error = null;
    });
    final r = await widget.charge.start(_phone.text.trim(), _attemptKey!);
    if (!mounted) return;
    switch (r) {
      case Success(:final data):
        HapticFeedback.mediumImpact();
        _attemptKey = null;
        _startWaiting(data);
      case Failure(:final message, :final statusCode):
        setState(() {
          _stage = _Stage.ready;
          _error = message;
          // Only a request that may not have arrived is worth re-sending
          // under the same key.
          if (statusCode != null) _attemptKey = null;
        });
    }
  }

  void _startWaiting(ChargeStarted started) {
    _poll?.cancel();
    setState(() {
      _started = started;
      _stage = _Stage.waiting;
      _waitingSince = DateTime.now();
    });
    _poll = Timer.periodic(widget.pollEvery, (_) => _check());
  }

  Future<void> _check() async {
    final started = _started;
    if (started == null || _checking) return;
    _checking = true;
    final Result<ChargeProgress> r;
    try {
      r = await widget.charge.check(started.paymentId);
    } finally {
      _checking = false;
    }
    if (!mounted || _stage != _Stage.waiting) return;
    if (r case Success(:final data)) {
      if (data.succeeded) {
        _poll?.cancel();
        HapticFeedback.heavyImpact();
        if (widget.popOnPaid) {
          Navigator.of(context).pop(true);
          return;
        }
        setState(() {
          _progress = data;
          _stage = _Stage.paid;
        });
        return;
      }
      if (!data.pending) {
        _poll?.cancel();
        setState(() {
          _stage = _Stage.ready;
          _error = "M-Pesa didn't complete the payment. Nothing was charged - try again.";
        });
        return;
      }
    }
    if (DateTime.now().difference(_waitingSince!) >= widget.giveUpAfter) {
      _poll?.cancel();
      setState(() => _stage = _Stage.slow);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _stage == _Stage.ready || _stage == _Stage.prompting;
    return CheckoutScaffold(
      title: 'Pay with M-Pesa',
      icon: Icons.phone_android_rounded,
      body: _body(),
      bottom: ready
          ? CheckoutButton(
              key: const Key('mpesa-pay'),
              label: 'Pay KES ${formatKesAmount(widget.order.total)}',
              busy: _stage == _Stage.prompting,
              onPressed: _pay,
            )
          : null,
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.waiting:
        return CheckoutMessage(
          key: const Key('checkout-waiting'),
          icon: Icons.phone_android_rounded,
          iconColor: BrokaColors.neonGreen,
          title: 'Check your phone',
          body: 'We sent an M-Pesa prompt to ${_phone.text.trim()}. Enter your PIN to pay '
              'KES ${formatKesAmount(_started?.amount ?? widget.order.total)}. '
              'This screen updates as soon as M-Pesa confirms.',
          busy: true,
        );
      case _Stage.slow:
        return CheckoutMessage(
          key: const Key('checkout-slow'),
          icon: Icons.hourglass_bottom_rounded,
          title: 'Waiting for M-Pesa',
          body: "M-Pesa hasn't confirmed yet. If you entered your PIN, it goes through as soon "
              'as M-Pesa does - you can close this and come back.',
          action: 'Check again',
          onAction: () => _startWaiting(_started!),
        );
      case _Stage.paid:
        return CheckoutMessage(
          key: const Key('checkout-paid'),
          icon: Icons.check_circle_rounded,
          iconColor: BrokaColors.neonGreen,
          title: widget.success.title,
          body: widget.success.body(_progress?.paidUntil),
          action: 'Done',
          onAction: () => Navigator.of(context).pop(true),
        );
      case _Stage.ready:
      case _Stage.prompting:
        return _form();
    }
  }

  Widget _form() {
    final busy = _stage == _Stage.prompting;
    // Not a ListView: a lazily built list drops the phone field (and its
    // focus) when it scrolls out of view.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const CheckoutLabel('M-Pesa number'),
        const SizedBox(height: 10),
        CheckoutCard(
          accent: BrokaColors.neonGreen,
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(children: [
            const Icon(Icons.phone_android_rounded, color: BrokaColors.neonGreen, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: const Key('mpesa-phone'),
                controller: _phone,
                focusNode: _phoneFocus,
                enabled: !busy,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]'))],
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                decoration: const InputDecoration(
                  hintText: '0712 345 678',
                  hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 20),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _attemptKey = null;
                }),
              ),
            ),
            IconButton(
              key: const Key('mpesa-phone-edit'),
              tooltip: 'Change number',
              onPressed: busy ? null : () => _phoneFocus.requestFocus(),
              icon: const Icon(Icons.edit_rounded, color: BrokaColors.textMid, size: 20),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        const Text('The payment prompt goes to this number. Tap it to pay from a different line.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              key: const Key('checkout-error'),
              style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 24),
        const CheckoutLabel("You're paying for"),
        const SizedBox(height: 10),
        OrderSummary(order: widget.order),
      ]),
    );
  }
}
