// BROKA - Terms of Use and Service (2026-10-12).
//
// The text is assets/legal/terms.md, the one copy of the Terms: what the app
// shows is what the repository holds (TERMS.md points there). Rendered here
// from the small part of Markdown it uses - "#" and "##" headings,
// paragraphs, "- " bullets, **bold** and _italic_ - rather than pulling in a
// Markdown package for one screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../main.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';

/// Drawn in Home's language (2026-10-12): the constellation, the collapsing
/// header every destination has, and each numbered section on a glass card
/// with a glowing number. It was a bare AppBar over a page of grey text -
/// the one screen that looked like it came from another app.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key, this.animateBackground = true});

  static const asset = 'assets/legal/terms.md';
  static const gradient = [BrokaColors.neonPurple, BrokaColors.neonBlue];

  /// False under widget tests: the sky never settles.
  final bool animateBackground;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: animateBackground,
        child: SafeArea(
          bottom: false,
          child: FutureBuilder<String>(
            future: rootBundle.loadString(asset),
            builder: (context, snap) {
              final text = snap.data;
              final sections = text == null ? const <TermsSection>[] : termsSections(termsBlocks(text));
              return CustomScrollView(slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: 'Terms',
                    emoji: '📜',
                    gradient: gradient,
                    onBack: () => Navigator.maybePop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                  ),
                ),
                if (text == null)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold)),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, media.padding.bottom + 32),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (_, i) => sections[i].build(),
                        childCount: sections.length,
                      ),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

/// A heading and what follows it, up to the next heading - one card. The
/// blocks before the first heading (the title, the date, the opening) are
/// the introduction.
class TermsSection {
  const TermsSection(this.heading, this.blocks);
  final TermsBlock? heading;
  final List<TermsBlock> blocks;

  Widget build() {
    final h = heading;
    if (h == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14, top: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final b in blocks) b.build(),
        ]),
      );
    }
    final match = RegExp(r'^(\d+)\.\s*(.*)$').firstMatch(h.text);
    final number = match?.group(1);
    final title = match?.group(2) ?? h.text;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (number != null) ...[
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: TermsScreen.gradient),
                boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.45), blurRadius: 10)],
              ),
              child: Text(number,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12.5)),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w800, color: BrokaColors.textHigh)),
          ),
        ]),
        const SizedBox(height: 10),
        for (final b in blocks) b.build(),
      ]),
    );
  }
}

List<TermsSection> termsSections(List<TermsBlock> blocks) {
  final out = <TermsSection>[];
  TermsBlock? heading;
  var body = <TermsBlock>[];
  for (final b in blocks) {
    if (b.kind == TermsBlockKind.heading) {
      if (heading != null || body.isNotEmpty) out.add(TermsSection(heading, body));
      heading = b;
      body = <TermsBlock>[];
    } else {
      body.add(b);
    }
  }
  if (heading != null || body.isNotEmpty) out.add(TermsSection(heading, body));
  return out;
}

enum TermsBlockKind { title, heading, paragraph, bullet }

class TermsBlock {
  const TermsBlock(this.kind, this.text);
  final TermsBlockKind kind;
  final String text;

  Widget build() => switch (kind) {
        TermsBlockKind.title => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // Not ZoneGlowText: that one shouts in capitals.
            child: ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (b) => const LinearGradient(colors: [Colors.white, Color(0xFFC4B5FD)])
                  .createShader(b),
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w900,
                      height: 1.2,
                      color: Colors.white,
                      shadows: [Shadow(color: BrokaColors.neonPurple, blurRadius: 18)])),
            ),
          ),
        TermsBlockKind.heading => Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 8),
            child: Text(text,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: BrokaColors.textHigh)),
          ),
        TermsBlockKind.paragraph => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(_inline(text), style: _body),
          ),
        TermsBlockKind.bullet => Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 5, height: 5,
                margin: const EdgeInsets.only(top: 8, right: 9),
                decoration: const BoxDecoration(shape: BoxShape.circle, color: BrokaColors.neonBlue),
              ),
              Expanded(child: Text.rich(_inline(text), style: _body)),
            ]),
          ),
      };

  static const _body = TextStyle(fontSize: 13.5, height: 1.55, color: Color(0xFFB4C0DA));
}

/// The Markdown, as blocks: lines of a paragraph or bullet joined, blank
/// lines ending them.
List<TermsBlock> termsBlocks(String markdown) {
  final out = <TermsBlock>[];
  TermsBlockKind? kind;
  final buffer = <String>[];

  void flush() {
    if (kind != null && buffer.isNotEmpty) out.add(TermsBlock(kind!, buffer.join(' ')));
    kind = null;
    buffer.clear();
  }

  for (final raw in markdown.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('## ')) {
      flush();
      out.add(TermsBlock(TermsBlockKind.heading, line.substring(3)));
    } else if (line.startsWith('# ')) {
      flush();
      out.add(TermsBlock(TermsBlockKind.title, line.substring(2)));
    } else if (line.startsWith('- ')) {
      flush();
      kind = TermsBlockKind.bullet;
      buffer.add(line.substring(2));
    } else {
      kind ??= TermsBlockKind.paragraph;
      buffer.add(line);
    }
  }
  flush();
  return out;
}

/// **bold** and _italic_ within a line.
TextSpan _inline(String text) {
  final spans = <TextSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*|_(.+?)_');
  var at = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(m.group(1) != null
        ? TextSpan(text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.w800, color: BrokaColors.textHigh))
        : TextSpan(text: m.group(2), style: const TextStyle(fontStyle: FontStyle.italic)));
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(children: spans);
}
