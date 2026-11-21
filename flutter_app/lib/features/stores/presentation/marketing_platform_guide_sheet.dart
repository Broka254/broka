part of 'marketing_studio_screen.dart';

// ── Platform guide sheet ────────────────────────────────────────────────────

Future<void> showPlatformGuideSheet(
  BuildContext context, {
  required StoresRepository repo,
  required String storeId,
  required String platform,
  required ValueChanged<SidekickAction> onAction,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _PlatformGuideSheet(
        repo: repo,
        storeId: storeId,
        platform: platform,
        onAction: onAction,
      ),
    );

class _PlatformGuideSheet extends StatefulWidget {
  const _PlatformGuideSheet({
    required this.repo,
    required this.storeId,
    required this.platform,
    required this.onAction,
  });
  final StoresRepository repo;
  final String storeId;
  final String platform;
  final ValueChanged<SidekickAction> onAction;

  @override
  State<_PlatformGuideSheet> createState() => _PlatformGuideSheetState();
}

class _PlatformGuideSheetState extends State<_PlatformGuideSheet> {
  PlatformGuide? _guide;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result =
        await widget.repo.getPlatformGuide(widget.storeId, widget.platform);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _guide = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  void _run(SidekickAction action) {
    Navigator.of(context).pop();
    widget.onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final guide = _guide;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: ListView(
          key: const Key('platform-guide-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Text(guide?.label ?? 'Platform guide',
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(
                      child:
                          CircularProgressIndicator(color: BrokaColors.gold)))
            else if (_error != null)
              _InlineError(message: _error!, onRetry: _load)
            else if (guide != null) ...[
              Text(guide.summary,
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 12.5, height: 1.5)),
              const SizedBox(height: 6),
              Text('Best for: ${guide.bestFor}',
                  style: const TextStyle(
                      color: BrokaColors.textLow, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 12),
              if (guide.formats.isNotEmpty) ...[
                _sectionLabel('Formats'),
                for (final format in guide.formats)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.rectangle_outlined,
                              size: 14, color: BrokaColors.textMid),
                          const SizedBox(width: 7),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(format.label,
                                    style: const TextStyle(
                                        color: BrokaColors.textHigh,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600)),
                                if (format.tip.isNotEmpty)
                                  Text(format.tip,
                                      style: const TextStyle(
                                          color: BrokaColors.textMid,
                                          fontSize: 11.5,
                                          height: 1.35)),
                              ])),
                        ]),
                  ),
                const SizedBox(height: 8),
              ],
              for (final section in guide.sections)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    key: Key('guide-section-${section.key}'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: BrokaColors.bgCard.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: BrokaColors.border),
                    ),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(section.title,
                              style: const TextStyle(
                                  color: BrokaColors.textHigh,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                          if (section.summary.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(section.summary,
                                style: const TextStyle(
                                    color: BrokaColors.textMid,
                                    fontSize: 11.5,
                                    height: 1.4)),
                          ],
                          const SizedBox(height: 7),
                          for (final step in section.steps)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.only(top: 5),
                                      child: Icon(Icons.circle,
                                          size: 5, color: BrokaColors.textLow),
                                    ),
                                    const SizedBox(width: 7),
                                    Expanded(
                                        child: Text(step,
                                            style: const TextStyle(
                                                color: BrokaColors.textMid,
                                                fontSize: 11.5,
                                                height: 1.4))),
                                  ]),
                            ),
                        ]),
                  ),
                ),
              if (guide.example != null) ...[
                _sectionLabel('Caption starter from your store'),
                Container(
                  key: const Key('guide-example'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: BrokaColors.gold.withOpacity(0.4)),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(guide.example!.label,
                            style: const TextStyle(
                                color: BrokaColors.gold,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        SelectableText(guide.example!.body,
                            style: const TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: 12.5,
                                height: 1.45)),
                        if (guide.example!.hashtags.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                              guide.example!.hashtags
                                  .map((t) => '#$t')
                                  .join(' '),
                              style: const TextStyle(
                                  color: _accent, fontSize: 11.5)),
                        ],
                        const SizedBox(height: 6),
                        Text(guide.example!.note,
                            style: const TextStyle(
                                color: BrokaColors.textLow,
                                fontSize: 10.5,
                                height: 1.35)),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _copy(
                                context, guide.example!.shareable, 'Caption'),
                            icon: const Icon(Icons.copy_rounded, size: 15),
                            label: const Text('Copy'),
                          ),
                        ),
                      ]),
                ),
              ],
              if (guide.actions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final action in guide.actions)
                    OutlinedButton(
                      key: Key('guide-action-${action.type}'),
                      onPressed: () => _run(action),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BrokaColors.textHigh,
                        side: const BorderSide(color: BrokaColors.border),
                      ),
                      child: Text(action.label),
                    ),
                ]),
              ],
              const SizedBox(height: 8),
              Text(guide.note,
                  style: const TextStyle(
                      color: BrokaColors.textLow, fontSize: 10.5, height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}
