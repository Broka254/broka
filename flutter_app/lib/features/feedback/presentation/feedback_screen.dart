// Feedback & complaints: tell BROKA what works, what doesn't, or report
// a problem that needs a human. Submissions go to POST /feedback; the
// history (GET /feedback) shows each one's progress - sent, seen by a
// person, being worked on, done - and the team's reply, so a complaint is
// never a message into the void. The team's reply also arrives as a push
// (type feedback_update), which opens this screen.
//
// Opened from a listing ("Report a problem"), the form arrives pre-filled
// through route arguments ({kind, category, relatedListingId,
// relatedUserId, relatedDealId, contextLabel}) and the complaint carries
// what it is about to the admin queue.
//
// Complaints about a specific deal's money belong in a dispute instead -
// only a dispute can rule on escrow - and the form says so, with a way
// there when the complaint names a deal.
import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../utils/auth_gate.dart';
import '../../../widgets/chat_parts.dart' show kChatGradient;
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../../buy_agent/presentation/widgets/agent_hud.dart' show AgentHoloBorder;
import '../../communications/presentation/announcement_presentation.dart';
import '../data/repositories/feedback_repository.dart';
import '../domain/models/feedback.dart';

const Map<String, IconData> _categoryIcons = {
  'general': Icons.chat_bubble_outline_rounded,
  'bug': Icons.bug_report_outlined,
  'suggestion': Icons.lightbulb_outline_rounded,
  'compliment': Icons.favorite_border_rounded,
  'account': Icons.person_outline_rounded,
  'payments': Icons.payments_outlined,
  'listing': Icons.sell_outlined,
  'seller_conduct': Icons.storefront_outlined,
  'buyer_conduct': Icons.shopping_bag_outlined,
  'delivery': Icons.local_shipping_outlined,
  'safety': Icons.shield_outlined,
  'other': Icons.more_horiz_rounded,
};

Color _severityColor(String severity) {
  switch (severity) {
    case 'low':
      return BrokaColors.neonGreen;
    case 'high':
      return BrokaColors.warning;
    case 'urgent':
      return BrokaColors.danger;
    case 'normal':
    default:
      return BrokaColors.neonBlue;
  }
}

Color _statusColor(FeedbackStatus status) {
  switch (status) {
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

const List<String> _stageNames = ['Sent', 'Seen', 'Working', 'Done'];

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({
    super.key,
    this.repository,
    this.animateBackground = true,
    this.initialKind,
    this.initialCategory,
    this.relatedListingId,
    this.relatedDealId,
    this.relatedUserId,
    this.contextLabel,
  });

  final FeedbackRepository? repository;
  final bool animateBackground;

  /// Pre-fill: 'feedback' or 'complaint', and one of kFeedbackCategories.
  /// Route arguments with the same names do the same for '/feedback'.
  final String? initialKind;
  final String? initialCategory;

  /// What the complaint is about, carried to the admin queue.
  final String? relatedListingId;
  final String? relatedDealId;
  final String? relatedUserId;

  /// How the form names that thing ("Samsung A54, KES 25,000").
  final String? contextLabel;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  FeedbackRepository get _repo => widget.repository ?? feedbackRepository;

  String _kind = 'feedback';
  String _category = 'general';
  String _severity = 'normal';
  String? _relatedListingId;
  String? _relatedDealId;
  String? _relatedUserId;
  String? _contextLabel;
  bool _routeArgsRead = false;

  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _scroll = ScrollController();
  bool _submitting = false;
  String? _formError;

  List<FeedbackSubmission> _history = [];
  bool _historyLoading = true;
  String? _historyError;
  String _filter = 'all';
  String? _justSentId;

  @override
  void initState() {
    super.initState();
    _prefill(
      kind: widget.initialKind,
      category: widget.initialCategory,
      listingId: widget.relatedListingId,
      dealId: widget.relatedDealId,
      userId: widget.relatedUserId,
      label: widget.contextLabel,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeArgsRead) return;
    _routeArgsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      String? read(String key) {
        final value = args[key];
        return value is String && value.trim().isNotEmpty ? value.trim() : null;
      }

      _prefill(
        kind: read('kind'),
        category: read('category'),
        listingId: read('relatedListingId'),
        dealId: read('relatedDealId'),
        userId: read('relatedUserId'),
        label: read('contextLabel'),
      );
    }
  }

  void _prefill({
    String? kind,
    String? category,
    String? listingId,
    String? dealId,
    String? userId,
    String? label,
  }) {
    if (kind == 'feedback' || kind == 'complaint') _kind = kind!;
    if (category != null && kFeedbackCategories.containsKey(category)) {
      _category = category;
    }
    _relatedListingId = listingId ?? _relatedListingId;
    _relatedDealId = dealId ?? _relatedDealId;
    // Never about yourself: the server refuses it, and it is a slip.
    if (userId != null && userId != ApiService.currentUserId) {
      _relatedUserId = userId;
    }
    _contextLabel = label ?? _contextLabel;
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    _scroll.dispose();
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

  bool get _hasContext =>
      _relatedListingId != null || _relatedDealId != null || _relatedUserId != null;

  void _clearContext() => setState(() {
        _relatedListingId = null;
        _relatedDealId = null;
        _relatedUserId = null;
        _contextLabel = null;
      });

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
      relatedListingId: _relatedListingId,
      relatedDealId: _relatedDealId,
      relatedUserId: _relatedUserId,
    );
    if (!mounted) return;
    switch (result) {
      case Success(:final data):
        _subject.clear();
        _body.clear();
        setState(() {
          _submitting = false;
          _justSentId = data.id;
          _filter = 'all';
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_kind == 'complaint'
              ? 'Complaint received (${data.reference}). Track it under Your submissions.'
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

  void _followUp(FeedbackSubmission s) {
    setState(() {
      _kind = s.isComplaint ? 'complaint' : 'feedback';
      _category = kFeedbackCategories.containsKey(s.category) ? s.category : 'general';
      _subject.text = s.subject.startsWith('Re: ') ? s.subject : 'Re: ${s.subject} ${s.reference}';
      _relatedListingId = s.relatedListingId;
      _relatedDealId = s.relatedDealId;
      _relatedUserId = s.relatedUserId;
      _contextLabel = s.relatedListingId != null || s.relatedDealId != null
          ? 'Follow-up to ${s.reference}'
          : null;
    });
    // Back up to the form, where the follow-up is already started.
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
    }
  }

  Future<void> _openDetail(FeedbackSubmission s) async {
    final followUp = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SubmissionDetailSheet(submission: s, repository: _repo),
    );
    if (followUp == true && mounted) _followUp(s);
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
              controller: _scroll,
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
                      _PulseStrip(
                        loading: _historyLoading,
                        open: _history.where((s) => !s.isClosed).length,
                        answered: _history.where((s) => s.hasReply).length,
                        resolved: _history.where((s) => s.isClosed).length,
                      ),
                      const SizedBox(height: 14),
                      _formCard(),
                      const SizedBox(height: 26),
                      _historyHeader(),
                      const SizedBox(height: 12),
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

  // ── The form ──────────────────────────────────────────────────────────────

  Widget _formCard() {
    final isComplaint = _kind == 'complaint';
    final accent = isComplaint ? BrokaColors.warning : BrokaColors.gold;
    const radius = BorderRadius.all(Radius.circular(22));
    return AgentHoloBorder(
      borderRadius: radius,
      live: _submitting,
      width: 1.2,
      glow: isComplaint ? 0.32 : 0.22,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xF2141B36), Color(0xF20A1120)],
          ),
          boxShadow: [
            BoxShadow(color: accent.withOpacity(0.14), blurRadius: 26, spreadRadius: 1),
            const BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 8)),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: _KindButton(
                key: const Key('feedback-kind-feedback'),
                label: 'Feedback',
                caption: 'Ideas & praise',
                icon: Icons.lightbulb_outline_rounded,
                colors: const [BrokaColors.neonPurple, BrokaColors.neonBlue],
                selected: !isComplaint,
                onTap: () => setState(() => _kind = 'feedback'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _KindButton(
                key: const Key('feedback-kind-complaint'),
                label: 'Complaint',
                caption: 'Needs fixing',
                icon: Icons.report_problem_outlined,
                colors: const [BrokaColors.warning, BrokaColors.zoneOrange],
                selected: isComplaint,
                onTap: () => setState(() => _kind = 'complaint'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(
              isComplaint
                  ? 'Problems that need a remedy: conduct, payments, delivery, safety. '
                      'A person picks it up and replies here. For money held on a specific '
                      'deal, open a dispute from that deal instead - only a dispute can rule on it.'
                  : 'Ideas, praise, or anything that felt off. A human reads every submission.',
              key: ValueKey(isComplaint),
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 12.5, height: 1.45),
            ),
          ),
          if (_hasContext) ...[
            const SizedBox(height: 12),
            _ContextChip(
              label: _contextLabel ??
                  (_relatedListingId != null
                      ? 'A listing'
                      : _relatedDealId != null
                          ? 'A deal'
                          : 'A trader'),
              kindLabel: _relatedListingId != null
                  ? 'About this listing'
                  : _relatedDealId != null
                      ? 'About this deal'
                      : 'About this trader',
              onClear: _clearContext,
            ),
          ],
          const SizedBox(height: 14),
          _label('Category'),
          DropdownButtonFormField<String>(
            key: const Key('feedback-category'),
            value: _category,
            dropdownColor: BrokaColors.bgCard,
            iconEnabledColor: BrokaColors.textMid,
            borderRadius: BorderRadius.circular(14),
            decoration: _inputDecoration(),
            items: kFeedbackCategories.entries
                .map((e) => DropdownMenuItem(
                    value: e.key,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_categoryIcons[e.key] ?? Icons.label_outline_rounded,
                          size: 17, color: BrokaColors.neonCyan),
                      const SizedBox(width: 10),
                      Text(e.value,
                          style: const TextStyle(
                              color: BrokaColors.textHigh, fontSize: 14)),
                    ])))
                .toList(),
            onChanged: (v) => setState(() => _category = v ?? 'general'),
          ),
          const SizedBox(height: 14),
          _label('How urgent is it?'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final value in const ['low', 'normal', 'high', 'urgent'])
              _SeverityChip(
                label: feedbackSeverityLabel(value),
                color: _severityColor(value),
                selected: _severity == value,
                onTap: () => setState(() => _severity = value),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.schedule_rounded, size: 13, color: _severityColor(_severity)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                kFeedbackSeverityHints[_severity] ?? '',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
              ),
            ),
          ]),
          if (isComplaint && (_category == 'payments' || _category == 'delivery')) ...[
            const SizedBox(height: 12),
            _DisputeHint(
              dealId: _relatedDealId,
              onOpenDispute: _relatedDealId == null
                  ? null
                  : () => Navigator.pushNamed(context, '/dispute', arguments: {
                        'dealId': _relatedDealId,
                        'listingName': _contextLabel ?? '',
                      }),
            ),
          ],
          const SizedBox(height: 14),
          _label('Subject'),
          TextField(
            key: const Key('feedback-subject'),
            controller: _subject,
            maxLength: 160,
            textCapitalization: TextCapitalization.sentences,
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
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
            decoration: _inputDecoration(
                hint: isComplaint
                    ? 'What happened, when, and who was involved'
                    : 'What happened, where, and what you expected'),
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
            colors: isComplaint
                ? const [BrokaColors.warning, BrokaColors.zoneOrange]
                : kChatGradient,
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.send_rounded, color: Colors.white, size: 17),
                    const SizedBox(width: 8),
                    Text(isComplaint ? 'File complaint' : 'Send feedback',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15)),
                  ]),
          ),
          const SizedBox(height: 14),
          const _NextSteps(),
        ]),
      ),
    );
  }

  // ── History ───────────────────────────────────────────────────────────────

  List<FeedbackSubmission> get _visibleHistory {
    switch (_filter) {
      case 'open':
        return _history.where((s) => !s.isClosed).toList();
      case 'done':
        return _history.where((s) => s.isClosed).toList();
      default:
        return _history;
    }
  }

  Widget _historyHeader() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: _SectionTitle('Your submissions')),
            if (_history.isNotEmpty)
              Text('${_history.length} total',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
          ]),
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (value, label) in const [
                ('all', 'All'),
                ('open', 'In progress'),
                ('done', 'Done'),
              ])
                _FilterChip(
                  key: Key('feedback-filter-$value'),
                  label: label,
                  selected: _filter == value,
                  onTap: () => setState(() => _filter = value),
                ),
            ]),
          ],
        ],
      );

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
              'its progress and any reply from the BROKA team.',
        ),
      ];
    }
    final visible = _visibleHistory;
    if (visible.isEmpty) {
      return [
        _HistoryMessage(
          icon: Icons.inbox_rounded,
          text: _filter == 'done'
              ? 'Nothing finished yet - the team is still on it.'
              : 'Everything you sent has been dealt with.',
        ),
      ];
    }
    return [
      for (final item in visible)
        _SubmissionCard(
          submission: item,
          fresh: item.id == _justSentId,
          onTap: () => _openDetail(item),
        ),
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
        fillColor: BrokaColors.bgMid.withOpacity(0.9),
        counterStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BrokaColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BrokaColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BrokaColors.neonCyan, width: 1.4),
        ),
      );
}

// ── Pieces ───────────────────────────────────────────────────────────────────

/// The top of the screen: what happens to what you send, and where yours
/// stand right now.
class _PulseStrip extends StatelessWidget {
  const _PulseStrip({
    required this.loading,
    required this.open,
    required this.answered,
    required this.resolved,
  });

  final bool loading;
  final int open;
  final int answered;
  final int resolved;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(colors: [
            BrokaColors.neonPurple.withOpacity(0.16),
            BrokaColors.neonCyan.withOpacity(0.06),
          ]),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.35)),
        ),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: BrokaColors.brandGradient),
              boxShadow: [
                BoxShadow(
                    color: BrokaColors.neonCyan.withOpacity(0.35), blurRadius: 16),
              ],
            ),
            child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('A person reads every one',
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                loading
                    ? 'Checking on what you sent before...'
                    : open + answered + resolved == 0
                        ? 'Replies come back here, with a notification.'
                        : '$open in progress · $answered answered · $resolved done',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
              ),
            ]),
          ),
        ]),
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
    required this.caption,
    required this.icon,
    required this.colors,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String caption;
  final IconData icon;
  final List<Color> colors;
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: 58),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: selected
                  ? LinearGradient(colors: [
                      colors.first.withOpacity(0.32),
                      colors.last.withOpacity(0.16),
                    ])
                  : null,
              color: selected ? null : BrokaColors.bgMid,
              border: Border.all(
                color: selected ? colors.first : BrokaColors.border,
                width: selected ? 1.4 : 1,
              ),
              boxShadow: selected
                  ? [BoxShadow(color: colors.first.withOpacity(0.28), blurRadius: 16)]
                  : const [],
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon,
                  size: 19,
                  color: selected ? BrokaColors.textHigh : BrokaColors.textMid),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            color: selected
                                ? BrokaColors.textHigh
                                : BrokaColors.textMid,
                            fontWeight: FontWeight.w800,
                            fontSize: 14)),
                    Text(caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 10.5)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      );
}

class _SeverityChip extends StatelessWidget {
  const _SeverityChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final Color color;
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? color.withOpacity(0.18) : BrokaColors.bgMid,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? color : BrokaColors.border,
                width: selected ? 1.3 : 1,
              ),
              boxShadow: selected
                  ? [BoxShadow(color: color.withOpacity(0.25), blurRadius: 12)]
                  : const [],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      color: selected
                          ? BrokaColors.textHigh
                          : BrokaColors.textMid,
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
            ]),
          ),
        ),
      );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: 'Show $label',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.neonCyan.withOpacity(0.14)
                  : BrokaColors.bgCard.withOpacity(0.6),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: selected ? BrokaColors.neonCyan : BrokaColors.border),
            ),
            child: Text(label,
                style: TextStyle(
                    color: selected ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
          ),
        ),
      );
}

class _ContextChip extends StatelessWidget {
  const _ContextChip({
    required this.kindLabel,
    required this.label,
    required this.onClear,
  });

  final String kindLabel;
  final String label;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('feedback-context'),
        padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
        decoration: BoxDecoration(
          color: BrokaColors.neonCyan.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.link_rounded, size: 17, color: BrokaColors.neonCyan),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kindLabel,
                  style: const TextStyle(
                      color: BrokaColors.neonCyan,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4)),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13)),
            ]),
          ),
          IconButton(
            tooltip: 'Not about this',
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18, color: BrokaColors.textMid),
          ),
        ]),
      );
}

class _DisputeHint extends StatelessWidget {
  const _DisputeHint({required this.dealId, required this.onOpenDispute});
  final String? dealId;
  final VoidCallback? onOpenDispute;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: BrokaColors.warning.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.warning.withOpacity(0.4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.gavel_rounded, size: 16, color: BrokaColors.warning),
            SizedBox(width: 8),
            Expanded(
              child: Text('Is money held on a deal?',
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 13,
                      fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 5),
          const Text(
            'Only a dispute can release or refund escrow. A complaint here gets a person '
            'to look into it, but it cannot move the money.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
          ),
          if (onOpenDispute != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onOpenDispute,
              icon: const Icon(Icons.gavel_rounded, size: 16),
              label: const Text('Open a dispute on this deal'),
              style: TextButton.styleFrom(
                foregroundColor: BrokaColors.warning,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ],
        ]),
      );
}

/// What happens after Send, in three steps, so nobody wonders.
class _NextSteps extends StatelessWidget {
  const _NextSteps();

  @override
  Widget build(BuildContext context) {
    Widget step(IconData icon, String text) => Expanded(
          child: Column(children: [
            Icon(icon, size: 17, color: BrokaColors.neonCyan),
            const SizedBox(height: 5),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 10.5, height: 1.3)),
          ]),
        );
    Widget arrow() => const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Icon(Icons.chevron_right_rounded, size: 16, color: BrokaColors.border),
        );
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      step(Icons.inventory_2_outlined, 'You get a reference'),
      arrow(),
      step(Icons.visibility_outlined, 'A person reads it'),
      arrow(),
      step(Icons.notifications_active_outlined, 'Their reply comes here'),
    ]);
  }
}

/// Four dots on a line: sent, seen, being worked on, done.
class _StageTrack extends StatelessWidget {
  const _StageTrack({required this.stage, required this.color});
  final int stage;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Progress: ${_stageNames[stage]}',
        excludeSemantics: true,
        child: Row(children: [
          for (var i = 0; i < _stageNames.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.only(bottom: 15),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    color: i <= stage ? color.withOpacity(0.8) : BrokaColors.border,
                  ),
                ),
              ),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i <= stage ? color : BrokaColors.bgMid,
                  border: Border.all(color: i <= stage ? color : BrokaColors.border, width: 1.5),
                  boxShadow: i == stage
                      ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 8)]
                      : const [],
                ),
              ),
              const SizedBox(height: 4),
              Text(_stageNames[i],
                  style: TextStyle(
                      color: i <= stage ? BrokaColors.textHigh : BrokaColors.textMid,
                      fontSize: 9.5,
                      fontWeight: i == stage ? FontWeight.w800 : FontWeight.w500)),
            ]),
          ],
        ]),
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
          borderRadius: BorderRadius.circular(16),
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
  const _SubmissionCard({
    required this.submission,
    required this.onTap,
    this.fresh = false,
  });
  final FeedbackSubmission submission;
  final VoidCallback onTap;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final s = submission;
    final status = _statusColor(s.status);
    final kindColor = s.isComplaint ? BrokaColors.warning : BrokaColors.gold;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        label: '${s.isComplaint ? 'Complaint' : 'Feedback'} ${s.reference}: ${s.subject}, '
            '${feedbackStatusLabel(s.status)}. Opens the details.',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: Key('feedback-item-${s.id}'),
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Ink(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    BrokaColors.bgCard.withOpacity(0.92),
                    BrokaColors.bgMid.withOpacity(0.92),
                  ],
                ),
                border: Border.all(
                  color: fresh ? BrokaColors.neonCyan : status.withOpacity(0.35),
                  width: fresh ? 1.4 : 1,
                ),
                boxShadow: fresh
                    ? [BoxShadow(color: BrokaColors.neonCyan.withOpacity(0.25), blurRadius: 16)]
                    : const [],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kindColor.withOpacity(0.14),
                      border: Border.all(color: kindColor.withOpacity(0.5)),
                    ),
                    child: Icon(
                      s.isComplaint
                          ? Icons.report_problem_outlined
                          : Icons.lightbulb_outline_rounded,
                      size: 16,
                      color: kindColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s.subject,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            height: 1.3)),
                  ),
                  const SizedBox(width: 8),
                  Text(s.reference,
                      style: const TextStyle(
                          color: BrokaColors.textMid,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6)),
                ]),
                const SizedBox(height: 8),
                Text(s.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
                const SizedBox(height: 12),
                _StageTrack(stage: s.stage, color: status),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (fresh)
                    const AnnouncementPill(
                      label: 'Just sent',
                      color: BrokaColors.neonCyan,
                      icon: Icons.bolt_rounded,
                    ),
                  AnnouncementPill(
                    label: s.isComplaint ? 'Complaint' : 'Feedback',
                    color: kindColor,
                    icon: s.isComplaint
                        ? Icons.report_problem_outlined
                        : Icons.lightbulb_outline_rounded,
                  ),
                  AnnouncementPill(
                    label: s.categoryLabel,
                    color: BrokaColors.neonBlue,
                    icon: _categoryIcons[s.category] ?? Icons.label_outline_rounded,
                  ),
                  AnnouncementPill(
                    label: feedbackStatusLabel(s.status),
                    color: status,
                    icon: Icons.circle_outlined,
                  ),
                ]),
                if (s.createdAt != null) ...[
                  const SizedBox(height: 9),
                  Row(children: [
                    const Icon(Icons.schedule_rounded,
                        size: 13, color: BrokaColors.textMid),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(AnnouncementPresentation.publishedLine(s.createdAt!),
                          style: const TextStyle(
                              color: BrokaColors.textMid, fontSize: 11.5)),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        size: 18, color: BrokaColors.textMid),
                  ]),
                ],
                if (s.adminResponse != null) ...[
                  const SizedBox(height: 10),
                  _ReplyBubble(text: s.adminResponse!, at: s.respondedAt, maxLines: 3),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyBubble extends StatelessWidget {
  const _ReplyBubble({required this.text, this.at, this.maxLines});
  final String text;
  final DateTime? at;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            BrokaColors.neonPurple.withOpacity(0.14),
            BrokaColors.neonBlue.withOpacity(0.08),
          ]),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(14),
          ),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.support_agent_rounded, size: 15, color: BrokaColors.gold),
            SizedBox(width: 6),
            Text('Reply from BROKA',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          Text(text,
              maxLines: maxLines,
              overflow: maxLines == null ? null : TextOverflow.ellipsis,
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13, height: 1.5)),
          if (at != null) ...[
            const SizedBox(height: 6),
            Text(AnnouncementPresentation.fullDateTime(at!),
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
          ],
        ]),
      );
}

/// One submission in full: the whole text, every step with its time, the
/// reply, and a way to follow up. Re-reads it from the server on open, so
/// a reply that arrived since the list loaded is shown.
class _SubmissionDetailSheet extends StatefulWidget {
  const _SubmissionDetailSheet({required this.submission, required this.repository});
  final FeedbackSubmission submission;
  final FeedbackRepository repository;

  @override
  State<_SubmissionDetailSheet> createState() => _SubmissionDetailSheetState();
}

class _SubmissionDetailSheetState extends State<_SubmissionDetailSheet> {
  late FeedbackSubmission _s = widget.submission;
  bool _refreshing = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final result = await widget.repository.get(widget.submission.id);
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      if (result case Success(:final data)) _s = data;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final status = _statusColor(s.status);
    final media = MediaQuery.of(context);
    final steps = <(String, DateTime?, bool)>[
      ('Sent to the BROKA team', s.createdAt, true),
      ('Seen by a person', s.respondedAt, s.stage >= 1),
      ('Being worked on', null, s.stage >= 2),
      (s.status == FeedbackStatus.closed ? 'Closed' : 'Resolved', s.resolvedAt, s.stage >= 3),
    ];
    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.86),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: status.withOpacity(0.4)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + media.viewInsets.bottom),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                    color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: Text(s.subject,
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.3)),
              ),
              if (_refreshing)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: BrokaColors.neonCyan),
                ),
            ]),
            const SizedBox(height: 6),
            Text(
              '${s.reference} · ${s.categoryLabel} · ${s.severityLabel} priority',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
            ),
            const SizedBox(height: 16),
            for (final (label, at, done) in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 18, color: done ? status : BrokaColors.border),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(label,
                        style: TextStyle(
                            color: done ? BrokaColors.textHigh : BrokaColors.textMid,
                            fontSize: 13,
                            fontWeight: done ? FontWeight.w700 : FontWeight.w500)),
                  ),
                  if (at != null && done)
                    Text(AnnouncementPresentation.fullDateTime(at),
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
                ]),
              ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.7),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BrokaColors.border),
              ),
              child: SelectableText(s.body,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, height: 1.5)),
            ),
            if (s.adminResponse != null) ...[
              const SizedBox(height: 12),
              _ReplyBubble(text: s.adminResponse!, at: s.respondedAt),
            ] else ...[
              const SizedBox(height: 12),
              const Text(
                'No reply yet. You will get a notification when the team answers.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5),
              ),
            ],
            if (s.relatedListingId != null || s.relatedDealId != null || s.relatedUserId != null) ...[
              const SizedBox(height: 12),
              Row(children: [
                const Icon(Icons.link_rounded, size: 15, color: BrokaColors.neonCyan),
                const SizedBox(width: 6),
                Text(
                  s.relatedDealId != null
                      ? 'Linked to a deal'
                      : s.relatedListingId != null
                          ? 'Linked to a listing'
                          : 'Linked to a trader',
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
                ),
              ]),
            ],
            const SizedBox(height: 18),
            GradientButton(
              onPressed: () => Navigator.pop(context, true),
              colors: kChatGradient,
              height: 46,
              child: const Text('Send a follow-up',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      ),
    );
  }
}
