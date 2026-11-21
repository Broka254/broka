part of 'marketing_studio_screen.dart';

// ── Video script sheet ──────────────────────────────────────────────────────

Future<void> showVideoScriptSheet(
  BuildContext context, {
  required StoresRepository repo,
  required String storeId,
  String? initialPlatform,
  String? initialProductId,
  String initialKind = 'script',
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _VideoScriptSheet(
        repo: repo,
        storeId: storeId,
        initialPlatform: initialPlatform,
        initialProductId: initialProductId,
        initialKind: initialKind,
      ),
    );

class _VideoScriptSheet extends StatefulWidget {
  const _VideoScriptSheet({
    required this.repo,
    required this.storeId,
    this.initialPlatform,
    this.initialProductId,
    this.initialKind = 'script',
  });
  final StoresRepository repo;
  final String storeId;
  final String? initialPlatform;
  final String? initialProductId;
  final String initialKind;

  @override
  State<_VideoScriptSheet> createState() => _VideoScriptSheetState();
}

class _VideoScriptSheetState extends State<_VideoScriptSheet> {
  late String _platform =
      const ['tiktok', 'instagram', 'facebook'].contains(widget.initialPlatform)
          ? widget.initialPlatform!
          : 'tiktok';
  late String _kind = widget.initialKind;
  VideoScript? _script;
  bool _busy = false;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.repo.generateVideoScript(
      widget.storeId,
      platform: _platform,
      kind: _kind,
      productIds: widget.initialProductId == null
          ? const []
          : [widget.initialProductId!],
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Success(:final data):
          _script = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final script = _script;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: ListView(
          key: const Key('video-script-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            const Text('Video script',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
              'A concept and shot list to film on your phone. BROKA does not make a '
              'video file.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final platform in const {
                'tiktok': 'TikTok',
                'instagram': 'Instagram',
                'facebook': 'Facebook',
              }.entries)
                _Chip(
                  key: Key('sheet-video-platform-${platform.key}'),
                  label: platform.value,
                  selected: _platform == platform.key,
                  onTap: () => setState(() => _platform = platform.key),
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final kind in const {
                'concept': 'Concept',
                'script': 'Script',
                'storyboard': 'Storyboard',
                'voice_over': 'Voice-over',
              }.entries)
                _Chip(
                  key: Key('sheet-video-kind-${kind.key}'),
                  label: kind.value,
                  selected: _kind == kind.key,
                  onTap: () => setState(() => _kind = kind.key),
                ),
            ]),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('sheet-video-generate'),
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.description_outlined, size: 17),
              label: Text(_busy ? 'Writing the script...' : 'Generate script'),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 46),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _InlineError(message: _error!, onRetry: _generate),
            ],
            if (script != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.movie_creation_outlined,
                            size: 15, color: BrokaColors.gold),
                        const SizedBox(width: 7),
                        Expanded(
                            child: Text(script.label,
                                style: const TextStyle(
                                    color: BrokaColors.gold,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700))),
                        Text(
                            '${script.aspectRatio} · ${script.durationSeconds}s',
                            style: const TextStyle(
                                color: BrokaColors.textLow, fontSize: 10.5)),
                      ]),
                      const SizedBox(height: 4),
                      Text(script.disclaimer,
                          style: const TextStyle(
                              color: BrokaColors.textMid,
                              fontSize: 10.5,
                              height: 1.35)),
                    ]),
              ),
              const SizedBox(height: 10),
              Text(script.title,
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              if (script.hook.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Hook: ${script.hook}',
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
              ],
              const SizedBox(height: 10),
              for (var i = 0; i < script.scenes.length; i++)
                Container(
                  key: Key('video-scene-$i'),
                  margin: const EdgeInsets.only(bottom: 7),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: BrokaColors.border),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text('Shot ${i + 1}',
                              style: const TextStyle(
                                  color: _accent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                          const Spacer(),
                          if (script.scenes[i].seconds > 0)
                            Text('${script.scenes[i].seconds}s',
                                style: const TextStyle(
                                    color: BrokaColors.textLow,
                                    fontSize: 10.5)),
                        ]),
                        const SizedBox(height: 3),
                        Text(script.scenes[i].shot,
                            style: const TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: 12,
                                height: 1.35)),
                        if (script.scenes[i].onScreenText.isNotEmpty)
                          Text('On screen: ${script.scenes[i].onScreenText}',
                              style: const TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 11.5,
                                  height: 1.35)),
                        if (script.scenes[i].voiceOver.isNotEmpty)
                          Text('Voice-over: ${script.scenes[i].voiceOver}',
                              style: const TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 11.5,
                                  height: 1.35)),
                      ]),
                ),
              if (script.caption.isNotEmpty) ...[
                _sectionLabel('Caption'),
                SelectableText(script.captionWithTags,
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 12.5,
                        height: 1.45)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('video-copy-caption'),
                    onPressed: () =>
                        _copy(context, script.captionWithTags, 'Caption'),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('Copy caption'),
                  ),
                ),
              ],
              if (script.voiceOver.isNotEmpty) ...[
                _sectionLabel('Voice-over'),
                SelectableText(script.voiceOver,
                    style: const TextStyle(
                        color: BrokaColors.textMid,
                        fontSize: 12,
                        height: 1.45)),
              ],
              if (script.fallbackReason != null) ...[
                const SizedBox(height: 8),
                Text(script.fallbackReason!,
                    style: const TextStyle(
                        color: BrokaColors.textLow,
                        fontSize: 10.5,
                        height: 1.4)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
