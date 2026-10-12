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

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const asset = 'assets/legal/terms.md';

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: BrokaColors.bg,
        appBar: AppBar(
          backgroundColor: BrokaColors.bg,
          elevation: 0,
          title: const Text('Terms of Use',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: BrokaColors.textHigh)),
        ),
        body: FutureBuilder<String>(
          future: rootBundle.loadString(asset),
          builder: (context, snap) {
            final text = snap.data;
            if (text == null) {
              return const Center(child: CircularProgressIndicator(strokeWidth: 2));
            }
            final blocks = termsBlocks(text);
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
              itemCount: blocks.length,
              itemBuilder: (_, i) => blocks[i].build(),
            );
          },
        ),
      );
}

enum TermsBlockKind { title, heading, paragraph, bullet }

class TermsBlock {
  const TermsBlock(this.kind, this.text);
  final TermsBlockKind kind;
  final String text;

  Widget build() => switch (kind) {
        TermsBlockKind.title => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(text,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
          ),
        TermsBlockKind.heading => Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 8),
            child: Text(text,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: BrokaColors.gold)),
          ),
        TermsBlockKind.paragraph => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(_inline(text), style: _body),
          ),
        TermsBlockKind.bullet => Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('•  ', style: _body),
              Expanded(child: Text.rich(_inline(text), style: _body)),
            ]),
          ),
      };

  static const _body = TextStyle(fontSize: 14, height: 1.5, color: BrokaColors.textMid);
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
