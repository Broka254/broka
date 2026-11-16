// Report a suspected scam: who or what, why, the transaction reference, and
// optional screenshots - sent to POST /scam-reports and /{id}/evidence.
//
// WHAT THE PERSON IS TOLD, because it is the point of the screen: that the
// team will REVIEW it; that a report is not a finding against anyone; that
// BROKA cannot promise to recover money sent to a person or an escrow
// provider; and what to do next (keep the evidence, contact the provider
// itself, contact the payment provider, report crime to the police).
//
// WHAT IT NEVER ASKS FOR: a PIN, an OTP or a password. The form has no field
// for one, and says so in words next to the description, because people
// pasting a whole message into a box is how a code ends up in a database.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors/user_facing_error.dart';
import '../../core/network/api_client.dart';
import '../../core/utils/result.dart';
import '../../main.dart';
import '../../utils/auth_gate.dart';
import '../../widgets/chat_ambient_background.dart';

/// What the server answered to a filed report.
class ScamReportReceipt {
  const ScamReportReceipt({required this.id, required this.message, required this.nextSteps, required this.duplicate});
  final String id;
  final String message;
  final List<String> nextSteps;
  final bool duplicate;
}

class ScamReportRepository {
  ScamReportRepository({ApiClient? client}) : _client = client ?? apiClient;
  final ApiClient _client;

  Future<Result<ScamReportReceipt>> submit({
    required String reasonCode,
    required String description,
    String? reportedAccount,
    String? providerId,
    String? transactionReference,
    int? amountKes,
    bool paymentSent = false,
  }) async {
    try {
      final data = await _client.post('/scam-reports', {
        'reason_code': reasonCode,
        'description': description,
        if (reportedAccount != null && reportedAccount.isNotEmpty) 'reported_account_ref': reportedAccount,
        if (providerId != null) 'provider_id': providerId,
        if (transactionReference != null && transactionReference.isNotEmpty) 'transaction_reference': transactionReference,
        if (amountKes != null) 'amount_kes': amountKes,
        'payment_sent': paymentSent,
      });
      final m = data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
      final id = m['id'];
      if (id is! String) return const Failure('Something went wrong. Please try again.');
      return Success(ScamReportReceipt(
        id: id,
        message: m['message'] is String ? m['message'] as String : '',
        nextSteps: m['next_steps'] is List ? (m['next_steps'] as List).whereType<String>().toList() : const [],
        duplicate: m['duplicate'] == true,
      ));
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode, code: e.code);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  /// Attach one screenshot to a report. The server decides what it really
  /// is from its bytes; anything that is not a PNG, JPEG or WebP is refused.
  Future<Result<void>> attach(String reportId, String fileName, List<int> bytes) async {
    try {
      await _client.post('/scam-reports/${Uri.encodeComponent(reportId)}/evidence', {
        'file_name': fileName,
        'content_base64': base64Encode(bytes),
      });
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode, code: e.code);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

final scamReportRepository = ScamReportRepository();

/// The reasons a person can give. Same codes as the server's policy.REASONS.
const Map<String, String> kScamReasons = {
  'bypass_escrow': 'Asked me to skip escrow or pay outside it',
  'fake_escrow_link': 'Sent a fake or look-alike escrow link',
  'requested_otp_or_pin': 'Asked for my PIN, an OTP or a password',
  'deposit_to_reserve': 'Asked for a deposit to reserve an item',
  'fake_payment_proof': 'Sent a fake payment message or screenshot',
  'fake_customer_care': 'Pretended to be customer care or an escrow agent',
  'changed_payment_destination': 'Changed where to pay at the last minute',
  'non_delivery': 'Took payment and did not deliver',
  'not_as_described': 'The item or service was not as described',
  'other': 'Something else',
};

class ReportScamScreen extends StatefulWidget {
  const ReportScamScreen({
    super.key,
    this.providerId,
    this.reportedUserId,
    this.repository,
    this.pickImage,
    this.skipSignIn = false,
  });

  final String? providerId;
  final String? reportedUserId;
  final ScamReportRepository? repository;

  /// Tests pass this; the app opens the gallery.
  final Future<XFile?> Function()? pickImage;

  /// Tests: skip the sign-in gate.
  final bool skipSignIn;

  @override
  State<ReportScamScreen> createState() => _ReportScamScreenState();
}

class _ReportScamScreenState extends State<ReportScamScreen> {
  final _account = TextEditingController();
  final _reference = TextEditingController();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final List<XFile> _files = [];
  String? _reason;
  bool _paid = false;
  bool _sending = false;
  String? _error;
  ScamReportReceipt? _done;

  ScamReportRepository get _repo => widget.repository ?? scamReportRepository;

  @override
  void dispose() {
    _account.dispose();
    _reference.dispose();
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  bool get _ready =>
      _reason != null && _description.text.trim().length >= 10 && (_account.text.trim().length >= 3 || widget.reportedUserId != null);

  Future<void> _pick() async {
    if (_files.length >= 3) return;
    final picker = widget.pickImage ?? () => ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1600);
    final file = await picker();
    if (file != null && mounted) setState(() => _files.add(file));
  }

  Future<void> _send() async {
    if (!widget.skipSignIn && !await requireAuth(context, reason: 'to report a suspected scam')) return;
    if (!mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final amount = int.tryParse(_amount.text.replaceAll(RegExp(r'[^0-9]'), ''));
    final result = await _repo.submit(
      reasonCode: _reason!,
      description: _description.text.trim(),
      reportedAccount: _account.text.trim(),
      providerId: widget.providerId,
      transactionReference: _reference.text.trim(),
      amountKes: amount,
      paymentSent: _paid,
    );
    if (!mounted) return;
    if (result case Success(:final data)) {
      // Screenshots after the report exists; a failure to attach one does not undo the report.
      var skipped = 0;
      for (final f in _files) {
        final bytes = await f.readAsBytes();
        final ok = await _repo.attach(data.id, f.name, bytes);
        if (ok is Failure) skipped++;
      }
      if (!mounted) return;
      setState(() {
        _sending = false;
        _done = data;
        if (skipped > 0) {
          _error = '$skipped screenshot${skipped == 1 ? '' : 's'} could not be attached. Your report was still sent.';
        }
      });
    } else if (result case Failure(:final message)) {
      setState(() {
        _sending = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChatAmbientBackground(
      intensity: 0.85,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: BrokaColors.bg.withOpacity(0.55),
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text('REPORT A SUSPECTED SCAM',
              style: TextStyle(fontSize: 13, letterSpacing: 1.5, fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
          centerTitle: false,
        ),
        body: _done != null ? _thanks(_done!) : _form(),
      ),
    );
  }

  Widget _thanks(ScamReportReceipt r) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Icon(Icons.check_circle_outline_rounded, color: BrokaColors.neonGreen, size: 40),
      const SizedBox(height: 10),
      Text(r.duplicate ? 'You already reported this' : 'Thank you',
          key: const Key('report-thanks'),
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 20, fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      Text(r.message, style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.5)),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BrokaColors.warning, fontSize: 12.5))),
      const SizedBox(height: 14),
      const Text('What to do now', style: TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      for (final step in r.nextSteps)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  ', style: TextStyle(color: BrokaColors.textMid)),
            Expanded(child: Text(step, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.45))),
          ]),
        ),
      const SizedBox(height: 14),
      FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Done')),
    ]);
  }

  Widget _form() {
    const hint = TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
      const Text(
        'The Broka team will review this. A report is not a finding against anyone, and Broka cannot promise to '
        'recover money sent to a person or to an escrow provider.',
        style: hint,
      ),
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        key: const Key('reason-field'),
        value: _reason,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'What happened?', border: OutlineInputBorder()),
        items: [for (final e in kScamReasons.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
        onChanged: (v) => setState(() => _reason = v),
      ),
      const SizedBox(height: 12),
      if (widget.reportedUserId == null)
        TextField(
          key: const Key('account-field'),
          controller: _account,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Who or what is it about?',
            helperText: 'Their phone number, website address, name or Broka username',
            border: OutlineInputBorder(),
          ),
        ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('reference-field'),
        controller: _reference,
        decoration: const InputDecoration(
          labelText: 'Transaction reference (optional)',
          helperText: "From the provider or your M-Pesa message. Not your PIN, and never an OTP.",
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('description-field'),
        controller: _description,
        onChanged: (_) => setState(() {}),
        minLines: 4,
        maxLines: 8,
        maxLength: 4000,
        decoration: const InputDecoration(
          labelText: 'Tell us what happened',
          helperText: 'Do not write or paste your M-Pesa PIN, an OTP or a password here.',
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const Key('amount-field-report'),
        controller: _amount,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Amount involved in KSh (optional)', border: OutlineInputBorder()),
      ),
      SwitchListTile(
        key: const Key('paid-switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('I have already sent money', style: TextStyle(color: BrokaColors.textHigh, fontSize: 13.5)),
        value: _paid,
        onChanged: (v) => setState(() => _paid = v),
      ),
      const SizedBox(height: 6),
      const Text('Screenshots (optional, up to 3)', style: TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      const Text('Only Broka\'s team and you can see them. They can show phone numbers, so share only what is needed.', style: hint),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final (i, f) in _files.indexed)
          InputChip(label: Text(f.name, overflow: TextOverflow.ellipsis), onDeleted: () => setState(() => _files.removeAt(i))),
        if (_files.length < 3)
          ActionChip(key: const Key('add-screenshot'), avatar: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('Add screenshot'), onPressed: _pick),
      ]),
      if (_error != null)
        Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, key: const Key('report-error'), style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5))),
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('send-report'),
        onPressed: _ready && !_sending ? _send : null,
        style: FilledButton.styleFrom(backgroundColor: BrokaColors.neonPurple, padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        child: _sending
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Text('Send report'),
      ),
      const SizedBox(height: 10),
      const Text('If someone is asking for your PIN or an OTP right now, stop and do not share it. In an emergency, '
          'contact the police.', style: hint),
    ]);
  }
}
