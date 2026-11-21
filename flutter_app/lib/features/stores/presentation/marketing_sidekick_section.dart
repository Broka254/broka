part of 'marketing_studio_screen.dart';

// ── Sidekick ────────────────────────────────────────────────────────────────

class _ChatEntry {
  _ChatEntry.user(this.text)
      : role = 'user',
        reply = null,
        error = null,
        pending = false;
  _ChatEntry.pending()
      : role = 'assistant',
        text = '',
        reply = null,
        error = null,
        pending = true;
  _ChatEntry.answer(SidekickReply answer)
      : role = 'assistant',
        text = answer.reply,
        reply = answer,
        error = null,
        pending = false;
  _ChatEntry.failed(this.error)
      : role = 'assistant',
        text = '',
        reply = null,
        pending = false;

  final String role;
  final String text;
  final SidekickReply? reply;
  final String? error;
  final bool pending;
}

class _SidekickTab extends StatefulWidget {
  const _SidekickTab(
      {required this.store, required this.repo, required this.onAction});
  final Store store;
  final StoresRepository repo;
  final ValueChanged<SidekickAction> onAction;

  @override
  State<_SidekickTab> createState() => _SidekickTabState();
}

class _SidekickTabState extends State<_SidekickTab>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatEntry> _entries = [];
  CampaignPlatform? _platform;
  bool _busy = false;
  String? _lastFailed;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<({String role, String text})> get _history => [
        for (final entry in _entries)
          if (!entry.pending && entry.error == null)
            (
              role: entry.role,
              text: entry.role == 'assistant'
                  ? (entry.reply?.reply ?? '')
                  : entry.text
            ),
      ]
          .where((turn) => turn.text.trim().isNotEmpty)
          .toList()
          .reversed
          .take(8)
          .toList()
          .reversed
          .toList();

  Future<void> _send([String? preset]) async {
    if (_busy) return;
    final text = (preset ?? _controller.text).trim();
    if (text.isEmpty) return;
    final history = _history;
    setState(() {
      _entries.add(_ChatEntry.user(text));
      _entries.add(_ChatEntry.pending());
      _busy = true;
      _lastFailed = null;
      _controller.clear();
    });
    _scrollToEnd();
    final result = await widget.repo.sidekickChat(
      widget.store.id,
      message: text,
      platform: _platform?.value,
      history: history,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _entries.removeLast();
      switch (result) {
        case Success(:final data):
          _entries.add(_ChatEntry.answer(data));
          _lastFailed = null;
        case Failure(:final message):
          _entries.add(_ChatEntry.failed(message));
          _lastFailed = text;
      }
    });
    _scrollToEnd();
  }

  Future<void> _retry() async {
    final text = _lastFailed;
    if (text == null || _busy) return;
    setState(() {
      _entries.removeLast();
      _busy = true;
      _lastFailed = null;
    });
    final history = _history;
    setState(() => _entries.add(_ChatEntry.pending()));
    final result = await widget.repo.sidekickChat(
      widget.store.id,
      message: text,
      platform: _platform?.value,
      history: history,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _entries.removeLast();
      switch (result) {
        case Success(:final data):
          _entries.add(_ChatEntry.answer(data));
        case Failure(:final message):
          _entries.add(_ChatEntry.failed(message));
          _lastFailed = text;
      }
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent + 200,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lastReply = _entries.reversed
        .where((e) => e.reply != null)
        .map((e) => e.reply!)
        .firstOrNull;
    final suggestions = lastReply?.suggestions.isNotEmpty == true
        ? lastReply!.suggestions
        : const [
            'How should I market my store?',
            'Which social media platform suits my business?',
            'What content should I post this week?',
          ];
    return Column(
      key: const Key('marketing-sidekick'),
      children: [
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            children: [
              _PlatformChip(
                key: const Key('sidekick-platform-any'),
                label: 'Any platform',
                selected: _platform == null,
                onTap: () => setState(() => _platform = null),
              ),
              for (final platform in CampaignPlatform.values)
                _PlatformChip(
                  key: Key('sidekick-platform-${platform.value}'),
                  label: platform.label,
                  selected: _platform == platform,
                  onTap: () => setState(() =>
                      _platform = _platform == platform ? null : platform),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            key: const Key('sidekick-conversation'),
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              if (_entries.isEmpty) _sidekickWelcome(suggestions),
              for (final entry in _entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: entry.role == 'user'
                      ? _UserBubble(text: entry.text)
                      : entry.pending
                          ? const _TypingBubble()
                          : entry.error != null
                              ? _ErrorBubble(
                                  message: entry.error!, onRetry: _retry)
                              : _AnswerBubble(
                                  reply: entry.reply!,
                                  onAction: widget.onAction,
                                  onSuggestion: _send,
                                ),
                ),
              if (_entries.isNotEmpty && !_busy && suggestions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 2, bottom: 6),
                        child: Text('TRY NEXT',
                            style: TextStyle(
                                color: BrokaColors.textLow,
                                fontSize: 9.5,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w700)),
                      ),
                      SizedBox(
                        height: 34,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final suggestion in suggestions.take(3))
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ActionChip(
                                  key: Key(
                                      'sidekick-followup-${suggestion.hashCode}'),
                                  label: Text(suggestion,
                                      style: const TextStyle(
                                          color: BrokaColors.textMid,
                                          fontSize: 11.5)),
                                  backgroundColor:
                                      BrokaColors.bgCard.withOpacity(0.55),
                                  side: const BorderSide(
                                      color: BrokaColors.border),
                                  onPressed: () => _send(suggestion),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: TextField(
                  key: const Key('sidekick-input'),
                  controller: _controller,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  scrollPadding: const EdgeInsets.only(bottom: 150),
                  textInputAction: TextInputAction.send,
                  onTapOutside: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(
                      color: BrokaColors.textHigh, fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: _platform == null
                        ? 'Ask about marketing your store...'
                        : 'Ask about marketing on ${_platform!.label}...',
                    hintStyle: const TextStyle(
                        color: BrokaColors.textLow, fontSize: 13),
                    filled: true,
                    fillColor: BrokaColors.bgCard.withOpacity(0.6),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:
                            const BorderSide(color: BrokaColors.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:
                            const BorderSide(color: BrokaColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                height: 46,
                child: FilledButton(
                  key: const Key('sidekick-send'),
                  onPressed: _busy ? null : () => _send(),
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    backgroundColor: _accent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(23)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.arrow_upward_rounded,
                          size: 20, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _sidekickWelcome(List<String> suggestions) => _card(
        key: const Key('sidekick-welcome'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.16),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.auto_awesome_rounded,
                  color: _accent, size: 20),
            ),
            const SizedBox(width: 11),
            const Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What do you want to sell more of?',
                    style: TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 15,
                        fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text('Answers use your live products and their real prices.',
                    style:
                        TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
              ],
            )),
          ]),
          const SizedBox(height: 12),
          const Text('START WITH',
              style: TextStyle(
                  color: BrokaColors.textLow,
                  fontSize: 9.5,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          for (var i = 0; i < suggestions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: BrokaColors.bgMid.withOpacity(0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: BrokaColors.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: Key('sidekick-suggestion-$i'),
                  onTap: () => _send(suggestions[i]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 11, vertical: 10),
                    child: Row(children: [
                      Expanded(
                          child: Text(suggestions[i],
                              style: const TextStyle(
                                  color: BrokaColors.textHigh,
                                  fontSize: 12.5))),
                      const Icon(Icons.arrow_forward_rounded,
                          size: 15, color: BrokaColors.textMid),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class _PlatformChip extends StatelessWidget {
  const _PlatformChip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: selected
              ? BrokaColors.gold.withOpacity(0.16)
              : BrokaColors.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
                color: selected ? BrokaColors.gold : BrokaColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(label,
                  style: TextStyle(
                      color: selected ? BrokaColors.gold : BrokaColors.textMid,
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500)),
            ),
          ),
        ),
      );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82),
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.18),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(color: _accent.withOpacity(0.35)),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13, height: 1.4)),
        ),
      );
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Padding(
            padding: EdgeInsets.all(7),
            child: CircularProgressIndicator(
                strokeWidth: 2, color: BrokaColors.gold),
          ),
        ),
        const SizedBox(width: 9),
        Text('Checking your products...',
            style: TextStyle(
                color: BrokaColors.textMid.withOpacity(0.9), fontSize: 12.5)),
      ]);
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _card(
        key: const Key('sidekick-error'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.cloud_off_rounded, size: 17, color: BrokaColors.textMid),
            SizedBox(width: 8),
            Text('The Sidekick did not answer',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(message,
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('sidekick-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Try again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrokaColors.textHigh,
              side: const BorderSide(color: BrokaColors.border),
            ),
          ),
        ]),
      );
}

/// Long answers start collapsed so the conversation stays scannable; nothing
/// is truncated permanently, and the full text is always selectable.
class _AnswerBody extends StatefulWidget {
  const _AnswerBody({required this.text});
  final String text;

  @override
  State<_AnswerBody> createState() => _AnswerBodyState();
}

class _AnswerBodyState extends State<_AnswerBody> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final long = widget.text.length > 620;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          widget.text,
          maxLines: long && !_expanded ? 11 : null,
          style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 13, height: 1.5),
        ),
        if (long)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16),
              label: Text(_expanded ? 'Show less' : 'Read the full answer'),
              style: TextButton.styleFrom(
                foregroundColor: BrokaColors.textMid,
                padding: const EdgeInsets.only(top: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
      ],
    );
  }
}

class _AnswerBubble extends StatelessWidget {
  const _AnswerBubble(
      {required this.reply,
      required this.onAction,
      required this.onSuggestion});
  final SidekickReply reply;
  final ValueChanged<SidekickAction> onAction;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (reply.available ? _accent : BrokaColors.gold)
                  .withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              reply.available ? 'AI answer' : 'BROKA guidance',
              style: TextStyle(
                  color: reply.available ? _accent : BrokaColors.gold,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2),
            ),
          ),
          if (reply.platform != null) ...[
            const SizedBox(width: 6),
            Text(
                CampaignPlatform.parse(reply.platform)?.label ??
                    reply.platform!,
                style: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 10.5)),
          ],
        ]),
        const SizedBox(height: 9),
        _AnswerBody(text: reply.reply),
        if (reply.fallbackReason != null) ...[
          const SizedBox(height: 8),
          Text(reply.fallbackReason!,
              style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11, height: 1.4)),
        ],
        if (reply.products.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.inventory_2_outlined,
                size: 14, color: BrokaColors.textMid),
            const SizedBox(width: 6),
            Expanded(
                child: Text(
              reply.products
                  .map((p) => [p.name, p.priceLabel]
                      .whereType<String>()
                      .where((s) => s.isNotEmpty)
                      .join(' · '))
                  .join('  |  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
            )),
          ]),
        ],
        if (reply.actions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final action in reply.actions)
              OutlinedButton(
                key: Key('sidekick-action-${action.type}'
                    '${action.platform == null ? '' : '-${action.platform}'}'),
                onPressed: () => onAction(action),
                style: OutlinedButton.styleFrom(
                  foregroundColor: action.type == 'creative_studio'
                      ? BrokaColors.gold
                      : BrokaColors.textHigh,
                  side: BorderSide(
                      color: action.type == 'creative_studio'
                          ? BrokaColors.gold.withOpacity(0.7)
                          : BrokaColors.border),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(action.label,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
          ]),
        ],
        if (reply.suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final suggestion in reply.suggestions.take(2))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: InkWell(
                onTap: () => onSuggestion(suggestion),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    const Icon(Icons.north_east_rounded,
                        size: 12, color: BrokaColors.textLow),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(suggestion,
                            style: const TextStyle(
                                color: BrokaColors.textMid, fontSize: 11.5))),
                  ]),
                ),
              ),
            ),
        ],
      ]),
    );
  }
}
