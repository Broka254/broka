// Zeno's words, arriving the way a language model's do.
//
// A reply from Zeno should look like one: a moment of "thinking", then the
// text streaming in - a few words at a time, at an uneven pace, pausing
// after punctuation - each new word surfacing out of Zeno's gold into
// white, with a caret at the end until it's done. The bubble grows as the
// text does. [onDone] fires when the last word has landed, so what comes
// after (the answer buttons) can wait for the question.
//
// Under reduced motion (MediaQuery.disableAnimations) the whole text is
// shown at once. Screen readers get the whole text, never a half sentence.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../main.dart' show BrokaColors;

enum ZenoStreamPhase { thinking, writing, done }

// Word-sized pieces with the space after them, so a piece never splits a
// word (or an emoji) in half.
final _wordPieces = RegExp(r'\S+\s*');

/// How long to wait after [piece] before the next burst: a beat after the
/// end of a sentence, less after a comma, hardly any mid-sentence.
int _pauseAfterMs(String piece, Random rnd) {
  final last = piece.trimRight();
  if (RegExp(r'[.!?:]$').hasMatch(last)) return 180 + rnd.nextInt(220);
  if (last.endsWith(',')) return 90 + rnd.nextInt(90);
  return 35 + rnd.nextInt(70);
}

class ZenoStreamingBubble extends StatefulWidget {
  const ZenoStreamingBubble({
    super.key,
    required this.text,
    this.onDone,
    this.random,
  });

  /// Null while there is nothing to say yet: the bubble "thinks".
  final String? text;
  final VoidCallback? onDone;

  /// For tests.
  final Random? random;

  @override
  State<ZenoStreamingBubble> createState() => _ZenoStreamingBubbleState();
}

class _ZenoStreamingBubbleState extends State<ZenoStreamingBubble>
    with SingleTickerProviderStateMixin {
  late final Random _rnd = widget.random ?? Random();
  late final Ticker _ticker;
  // Milliseconds since the ticker started: the clock the fade-ins, the
  // dots and the caret all run on, so they move with the frames.
  int _nowMs = 0;
  Timer? _timer;

  ZenoStreamPhase _phase = ZenoStreamPhase.thinking;
  List<String> _tokens = const [];
  final List<int> _revealedAtMs = [];
  bool _started = false;

  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (!mounted) return;
      setState(() => _nowMs = elapsed.inMilliseconds);
      // Everything landed and faded in: nothing left to animate.
      if (_phase == ZenoStreamPhase.done &&
          (_revealedAtMs.isEmpty || _nowMs - _revealedAtMs.last > 400)) {
        _ticker.stop();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeStart();
  }

  @override
  void didUpdateWidget(covariant ZenoStreamingBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _timer?.cancel();
      _started = false;
      _maybeStart();
    }
  }

  void _maybeStart() {
    final text = widget.text;
    if (_started) return;
    if (_still) {
      if (text == null) return;
      _started = true;
      _tokens = _wordPieces.allMatches(text).map((m) => m.group(0)!).toList();
      _revealedAtMs
        ..clear()
        ..addAll(List.filled(_tokens.length, -100000));
      _phase = ZenoStreamPhase.done;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onDone?.call();
      });
      return;
    }
    _startTicker();
    if (text == null) return; // keep thinking until there's something to say
    _started = true;
    _tokens = _wordPieces.allMatches(text).map((m) => m.group(0)!).toList();
    _revealedAtMs.clear();
    _phase = ZenoStreamPhase.thinking;
    // A beat to "think" before the first word, never the same length twice.
    _timer = Timer(Duration(milliseconds: 750 + _rnd.nextInt(650)), () {
      if (!mounted) return;
      _phase = ZenoStreamPhase.writing;
      _emit();
    });
  }

  /// Sends the next burst of one to three words, then schedules the one
  /// after - quicker mid-sentence, slower after punctuation.
  void _emit() {
    if (!mounted) return;
    final now = _nowMs;
    final burst = 1 + _rnd.nextInt(3);
    for (var i = 0; i < burst && _revealedAtMs.length < _tokens.length; i++) {
      _revealedAtMs.add(now + i * 25);
    }
    if (_revealedAtMs.length >= _tokens.length) {
      // The ticker runs on until the last words have faded in.
      _phase = ZenoStreamPhase.done;
      widget.onDone?.call();
      return;
    }
    final pause = _pauseAfterMs(_tokens[_revealedAtMs.length - 1], _rnd);
    _timer = Timer(Duration(milliseconds: pause), _emit);
  }

  void _startTicker() {
    if (_ticker.isActive) return;
    // A restarted ticker counts from zero again (new text only - the
    // words it times are cleared with it).
    _nowMs = 0;
    _ticker.start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text ?? '';
    final now = _nowMs;
    return Semantics(
      label: text.isEmpty ? 'Zeno is thinking' : text,
      liveRegion: true,
      excludeSemantics: true,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(6), topRight: Radius.circular(20),
              bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20),
            ),
            gradient: LinearGradient(colors: [
              BrokaColors.gold.withOpacity(0.28), BrokaColors.neonBlue.withOpacity(0.16),
            ]),
            border: Border.all(color: BrokaColors.gold.withOpacity(0.55)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _status(now),
            const SizedBox(height: 8),
            if (_phase == ZenoStreamPhase.thinking) _thinking(now) else _words(now),
          ]),
        ),
      ),
    );
  }

  Widget _status(int now) {
    final (label, color) = switch (_phase) {
      ZenoStreamPhase.thinking => ('thinking', BrokaColors.textMid),
      ZenoStreamPhase.writing => ('writing', BrokaColors.neonCyan),
      ZenoStreamPhase.done => ('just now', BrokaColors.textMid),
    };
    return Row(children: [
      const Text('✦ ZENO', style: TextStyle(color: BrokaColors.gold, fontSize: 10.5,
          fontWeight: FontWeight.w900, letterSpacing: 1.4)),
      const SizedBox(width: 8),
      if (_phase != ZenoStreamPhase.done)
        SizedBox(
          width: 10, height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            value: _still ? 0.7 : null,
            color: color,
          ),
        )
      else
        const Icon(Icons.check_rounded, size: 12, color: BrokaColors.success),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700)),
    ]);
  }

  /// Three dots rising in turn, and "Zeno is thinking" with light running
  /// across it.
  Widget _thinking(int now) {
    final t = now / 1000.0;
    return Row(children: [
      for (var i = 0; i < 3; i++)
        Padding(
          padding: const EdgeInsets.only(right: 5),
          child: Transform.translate(
            offset: Offset(0, -4 * max(0.0, sin((t * 2 * pi * 1.4) - i * 0.9))),
            child: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(BrokaColors.gold, BrokaColors.neonCyan, i / 2),
              ),
            ),
          ),
        ),
      const SizedBox(width: 6),
      // Flexible: a narrow phone or large text wraps it, never overflows.
      Flexible(child: ShaderMask(
        shaderCallback: (rect) {
          final x = (t * 0.8) % 1.6 - 0.3;
          return LinearGradient(
            colors: const [BrokaColors.textMid, Colors.white, BrokaColors.textMid],
            stops: [(x - 0.2).clamp(0.0, 1.0), x.clamp(0.0, 1.0), (x + 0.2).clamp(0.0, 1.0)],
          ).createShader(rect);
        },
        child: const Text('Zeno is thinking…', style: TextStyle(color: Colors.white,
            fontSize: 14, fontStyle: FontStyle.italic)),
      )),
    ]);
  }

  Widget _words(int now) {
    const base = TextStyle(color: Colors.white, fontSize: 15, height: 1.45, fontWeight: FontWeight.w600);
    final spans = <InlineSpan>[];
    for (var i = 0; i < _revealedAtMs.length && i < _tokens.length; i++) {
      final age = (now - _revealedAtMs[i]).clamp(0, 260) / 260.0;
      spans.add(TextSpan(
        text: _tokens[i],
        style: base.copyWith(
          color: Color.lerp(BrokaColors.gold, Colors.white, age)!.withOpacity(0.35 + 0.65 * age),
        ),
      ));
    }
    if (_phase == ZenoStreamPhase.writing) {
      final on = (now ~/ 420).isEven;
      spans.add(TextSpan(
        text: '▍',
        style: base.copyWith(color: BrokaColors.gold.withOpacity(on ? 1 : 0.25)),
      ));
    }
    return Text.rich(TextSpan(children: spans));
  }
}

/// Just the words of a reply, streaming in - for a chat bubble that has its
/// own frame, and that already showed typing dots while Zeno thought, so
/// the first words start at once instead of after a "thinking" beat.
///
/// One word at a time, at a steady reading pace (about 13 words a second),
/// with a beat after a comma or the end of a sentence. Each word fades in
/// from Zeno's violet over a little longer than the gap between words, so
/// the line flows rather than ticks, and the bubble grows smoothly. The
/// first version dropped one to three words at once every 35-105ms - about
/// twice this pace and in lumps - which read as jittery rather than typed.
/// A long reply goes faster per word instead of arriving in lumps, so it
/// still never takes much more than about seven seconds.
///
/// Only a reply that has just arrived streams ([animate]); one restored from
/// earlier, or scrolled back to, is simply there. Under reduced motion the
/// whole text is shown at once. Screen readers get the whole text, never
/// half a sentence.
class ZenoStreamingText extends StatefulWidget {
  const ZenoStreamingText(
    this.text, {
    super.key,
    required this.style,
    this.animate = true,
    this.onDone,
    this.onGrow,
    this.random,
  });

  final String text;
  final TextStyle style;
  final bool animate;

  /// Once every word is on screen - for what should wait for the reply
  /// (the listings the Buying Agent found, say).
  final VoidCallback? onDone;

  /// Every frame while the reply is being written, so the chat can follow
  /// the growing bubble smoothly rather than in jumps.
  final VoidCallback? onGrow;

  /// For tests.
  final Random? random;

  @override
  State<ZenoStreamingText> createState() => _ZenoStreamingTextState();
}

class _ZenoStreamingTextState extends State<ZenoStreamingText>
    with SingleTickerProviderStateMixin {
  /// The gap between words, before punctuation beats and jitter.
  static const _wordMs = 75;

  /// How long a new word takes to fade in - longer than [_wordMs], so each
  /// word is still arriving as the next starts.
  static const _fadeMs = 420;

  /// Roughly the longest a reply takes to write out.
  static const _longestMs = 7000;

  static final _sentenceEnd = RegExp(r'[.!?…]$');
  static final _clauseEnd = RegExp(r'[,;:]$');

  late final Random _rnd = widget.random ?? Random();
  // Only a reply that streams needs one; most never do.
  Ticker? _ticker;
  int _nowMs = 0;
  Timer? _timer;

  List<String> _pieces = const [];
  final List<int> _revealedAtMs = [];

  /// 1 for an ordinary reply; below 1 for a long one, to keep it near
  /// [_longestMs].
  double _pace = 1;
  bool _streaming = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!widget.animate || still || widget.text.trim().isEmpty) {
      if (widget.animate) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onDone?.call();
        });
      }
      return;
    }
    _pieces = _wordPieces.allMatches(widget.text).map((m) => m.group(0)!).toList();
    var estimate = 0;
    for (final p in _pieces) {
      estimate += _wordMs + _beatAfter(p.trimRight());
    }
    _pace = estimate > _longestMs ? max(0.3, _longestMs / estimate) : 1;
    _streaming = true;
    _ticker = createTicker(_onTick)..start();
    _emit();
  }

  /// The extra pause after [word]: a sentence ends, a clause ends, or not.
  int _beatAfter(String word) {
    if (_sentenceEnd.hasMatch(word)) return 230;
    if (_clauseEnd.hasMatch(word)) return 110;
    return 0;
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    setState(() => _nowMs = elapsed.inMilliseconds);
    widget.onGrow?.call();
    if (_revealedAtMs.length >= _pieces.length &&
        _nowMs - _revealedAtMs.last > _fadeMs) {
      _ticker?.stop();
      setState(() => _streaming = false);
      widget.onDone?.call();
    }
  }

  void _emit() {
    if (!mounted) return;
    _revealedAtMs.add(_nowMs);
    if (_revealedAtMs.length >= _pieces.length) return; // the ticker finishes
    final word = _pieces[_revealedAtMs.length - 1].trimRight();
    // A little unevenness (±10ms) so it doesn't read as a metronome.
    final gap = (_wordMs + _rnd.nextInt(21) - 10 + _beatAfter(word)) * _pace;
    _timer = Timer(Duration(milliseconds: gap.round()), _emit);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_streaming) return Text(widget.text, style: widget.style);
    final base = widget.style.color ?? Colors.white;
    final spans = <InlineSpan>[];
    for (var i = 0; i < _revealedAtMs.length; i++) {
      final t = Curves.easeOutCubic
          .transform((_nowMs - _revealedAtMs[i]).clamp(0, _fadeMs) / _fadeMs);
      spans.add(TextSpan(
        text: _pieces[i],
        style: TextStyle(
          color: Color.lerp(BrokaColors.neonPurple, base, t)!.withOpacity(t),
        ),
      ));
    }
    if (_revealedAtMs.length < _pieces.length) {
      // Steady, not blinking: a blink every 420ms fought the words' own
      // rhythm and made the line look busier than it is.
      spans.add(TextSpan(
        text: '▍',
        style: TextStyle(color: BrokaColors.neonBlue.withOpacity(0.85)),
      ));
    }
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      // A new line eases open instead of the bubble snapping a line taller.
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: Text.rich(TextSpan(style: widget.style, children: spans)),
      ),
    );
  }
}
