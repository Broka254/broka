// Feedback & complaints: tell BROKA what works, what doesn't, or report
// a problem that needs a human. Submissions go to POST /feedback; the
// history (GET /feedback) shows the status and the team's reply, so a
// complaint is never a message into the void.
//
// Complaints about a specific deal's money belong in a dispute instead -
// the form says so and links there - because only a dispute can rule on
// escrow. Everything else (conduct, bugs, payments flow, ideas) is here.
import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../utils/auth_gate.dart';
import '../../../widgets/chat_parts.dart' show kChatGradient;
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../../communications/presentation/announcement_presentation.dart';
import '../data/repositories/feedback_repository.dart';
import '../domain/models/feedback.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key, this.repository, this.animateBackground = true});

  final FeedbackRepository? repository;
  final bool animateBackground;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  FeedbackRepository get _repo => widget.repository ?? feedbackRepository;

  String _kind = 'feedback';
  String _category = 'general';
  String _severity = 'normal';
  final _subject = TextEditingController();
  final _body = TextEditingController();
  bool _submitting = false;
  String? _formError;

  List<FeedbackSubmission> _history = [];
  bool _historyLoading = true;
  String? _historyError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!ApiService.isLoggedIn) {
      final authed = await requireAuth(context,
          reason: 'to send feedback to BROKA');
      if (!mounted) return;
      if (!authed) {
        Navigator.maybePop(context);
        return;
      }
    }
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    final result = await _repo.mine();
    if (!mounted) return;
    switch (result) {
      case Success(:final data):
        setState(() {
          _history = data.items;
          _historyLoading = false;
          _historyError = null;
        });
      case Failure(:final message):
        setState(() {
          _historyLoading = false;
          _historyError = message;
        });
    }
  }

  Future<void> _submit() async {
    final subject = _subject.text.trim();
    final body = _body.text.trim();
    if (subject.isEmpty || body.isEmpty) {
      setState(() => _formError = 'Add a subject and a few details first.');
      return;
    }
    setState(() {
      _submitting = true;
      _formError = null;
    });
    final result = await _repo.submit(
      kind: _kind,
      category: _category,
      severity: _severity,
      subject: subject,
      body: body,
    );
    if (!mounted) return;
    switch (result) {
      case Success():
        _subject.clear();
        _body.clear();
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_kind == 'complaint'
              ? 'Complaint received. Reference it any time under Your submissions.'
              : 'Thanks - your feedback was sent.'),
        ));
        await _loadHistory();
      case Failure(:final message):
        setState(() {
          _submitting = false;
          _formError = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
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
            onRefresh: _loadHistory,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: 'Feedback & complaints',
                    emoji: '💬',
                    gradient: kChatGradient,
                    onBack: () => Navigator.maybePop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler
                        .scale(1.0)
                        .clamp(1.0, 1.35)
                        .toDouble(),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                      16, 4, 16, 24 + media.padding.bottom),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _formCard(),
                      const SizedBox(height: 22),
                      const _SectionTitle('Your submissions'),
                      const SizedBox(height: 10),
                      ..._historyWidgets(),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _formCard() {
    final isComplaint = _kind == 'complaint';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: _KindButton(
              key: const Key('feedback-kind-feedback'),
              label: 'Feedback',
              icon: Icons.lightbulb_outline_rounded,
              selected: !isComplaint,
              onTap: () => setState(() => _kind = 'feedback'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _KindButton(
              key: const Key('feedback-kind-complaint'),
              label: 'Complaint',
              icon: Icons.report_problem_outlined,
              selected: isComplaint,
              onTap: () => setState(() => _kind = 'complaint'),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Text(
          isComplaint
              ? 'Problems that need a remedy: conduct, payments, delivery, safety. '
                  'For money held on a specific deal, open a dispute from that deal instead - '
                  'only a dispute can rule on it.'
              : 'Ideas, praise, or anything that felt off. A human reads every submission.',
          style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12.5, height: 1.45),
        ),
        const SizedBox(height: 14),
        _label('Category'),
        DropdownButtonFormField<String>(
          key: const Key('feedback-category'),
          value: _category,
          dropdownColor: BrokaColors.bgCard,
          decoration: _inputDecoration(),
          items: kFeedbackCategories.entries
              .map((e) => DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value,
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontSize: 14))))
              .toList(),
          onChanged: (v) => setState(() => _category = v ?? 'general'),
        ),
        const SizedBox(height: 14),
        _label('How urgent is it?'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (value, label) in const [
            ('low', 'Low'),
            ('normal', 'Normal'),
            ('high', 'High'),
            ('urgent', 'Urgent'),
          ])
            _SeverityChip(
              label: label,
              selected: _severity == value,
              onTap: () => setState(() => _severity = value),
            ),
        ]),
        const SizedBox(height: 14),
        _label('Subject'),
        TextField(
          key: const Key('feedback-subject'),
          controller: _subject,
          maxLength: 160,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
          decoration: _inputDecoration(hint: 'Short summary'),
        ),
        const SizedBox(height: 6),
        _label('Details'),
        TextField(
          key: const Key('feedback-body'),
          controller: _body,
          maxLength: 5000,
          minLines: 4,
          maxLines: 8,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
          decoration: _inputDecoration(
              hint: 'What happened, where, and what you expected'),
        ),
        if (_formError != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.error_outline_rounded,
                size: 16, color: BrokaColors.danger),
            const SizedBox(width: 7),
            Expanded(
              child: Text(_formError!,
                  style: const TextStyle(
                      color: BrokaColors.danger, fontSize: 12.5)),
            ),
          ]),
        ],
        const SizedBox(height: 16),
        GradientButton(
          key: const Key('feedback-submit'),
          onPressed: _submitting ? null : _submit,
          colors: kChatGradient,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : Text(isComplaint ? 'File complaint' : 'Send feedback',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15)),
        ),
      ]),
    );
  }

  List<Widget> _historyWidgets() {
    if (_historyLoading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
              child: CircularProgressIndicator(
                  color: BrokaColors.gold, strokeWidth: 1.5)),
        ),
      ];
    }
    if (_historyError != null && _history.isEmpty) {
      return [
        _HistoryMessage(
          icon: Icons.cloud_off_rounded,
          text: _historyError!,
          actionLabel: 'Retry',
          onAction: _loadHistory,
        ),
      ];
    }
    if (_history.isEmpty) {
      return const [
        _HistoryMessage(
          icon: Icons.inbox_rounded,
          text: 'Nothing yet. What you send above will appear here with '
              'its status and any reply from the BROKA team.',
        ),
      ];
    }
    return [
      for (final item in _history) _SubmissionCard(submission: item),
    ];
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(text,
            style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
      );

  InputDecoration _inputDecoration({String? hint}) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 13),
        filled: true,
        fillColor: BrokaColors.bgMid,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BrokaColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BrokaColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BrokaColors.gold, width: 1.4),
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: BrokaColors.textHigh,
          fontSize: 15,
          fontWeight: FontWeight.w800));
}

class _KindButton extends StatelessWidget {
  const _KindButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.18)
                  : BrokaColors.bgMid,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? BrokaColors.gold : BrokaColors.border,
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon,
                  size: 18,
                  color: selected
                      ? BrokaColors.textHigh
                      : BrokaColors.textMid),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      color: selected
                          ? BrokaColors.textHigh
                          : BrokaColors.textMid,
                      fontWeight: FontWeight.w800,
                      fontSize: 14)),
            ]),
          ),
        ),
      );
}

class _SeverityChip extends StatelessWidget {
  const _SeverityChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: '$label severity',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.18)
                  : BrokaColors.bgMid,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? BrokaColors.gold : BrokaColors.border,
              ),
            ),
            child: Text(label,
                style: TextStyle(
                    color: selected
                        ? BrokaColors.textHigh
                        : BrokaColors.textMid,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
          ),
        ),
      );
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: BrokaColors.textMid),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12.5, height: 1.45)),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ]),
      );
}

class _SubmissionCard extends StatelessWidget {
  const _SubmissionCard({required this.submission});
  final FeedbackSubmission submission;

  Color get _statusColor {
    switch (submission.status) {
      case FeedbackStatus.open:
        return BrokaColors.warning;
      case FeedbackStatus.acknowledged:
        return BrokaColors.neonBlue;
      case FeedbackStatus.inProgress:
        return BrokaColors.neonPurple;
      case FeedbackStatus.resolved:
        return BrokaColors.neonGreen;
      case FeedbackStatus.closed:
        return BrokaColors.textMid;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = submission;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            s.isComplaint
                ? Icons.report_problem_outlined
                : Icons.lightbulb_outline_rounded,
            size: 17,
            color: s.isComplaint ? BrokaColors.warning : BrokaColors.gold,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(s.subject,
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.3)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(s.body,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          AnnouncementPill(
            label: s.isComplaint ? 'Complaint' : 'Feedback',
            color: s.isComplaint ? BrokaColors.warning : BrokaColors.gold,
            icon: s.isComplaint
                ? Icons.report_problem_outlined
                : Icons.lightbulb_outline_rounded,
          ),
          AnnouncementPill(
            label: s.categoryLabel,
            color: BrokaColors.neonBlue,
            icon: Icons.label_outline_rounded,
          ),
          AnnouncementPill(
            label: feedbackStatusLabel(s.status),
            color: _statusColor,
            icon: Icons.circle_outlined,
          ),
        ]),
        if (s.createdAt != null) ...[
          const SizedBox(height: 9),
          Row(children: [
            const Icon(Icons.schedule_rounded,
                size: 13, color: BrokaColors.textMid),
            const SizedBox(width: 5),
            Text(AnnouncementPresentation.publishedLine(s.createdAt!),
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 11.5)),
          ]),
        ],
        if (s.adminResponse != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: BrokaColors.bgMid,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.support_agent_rounded,
                        size: 15, color: BrokaColors.gold),
                    SizedBox(width: 6),
                    Text('Reply from BROKA',
                        style: TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 12,
                            fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 6),
                  Text(s.adminResponse!,
                      style: const TextStyle(
                          color: BrokaColors.textMid,
                          fontSize: 13,
                          height: 1.5)),
                  if (s.respondedAt != null) ...[
                    const SizedBox(height: 6),
                    Text(AnnouncementPresentation.fullDateTime(s.respondedAt!),
                        style: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 11)),
                  ],
                ]),
          ),
        ],
      ]),
    );
  }
}
