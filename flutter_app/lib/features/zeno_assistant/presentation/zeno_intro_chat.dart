// Zeno's introduction, on screen (zeno_intro.dart has the conversation):
// full screen over Home, the first time a new account sees it.
//
// It is drawn as one of BROKA's conversations, because that is what it is:
// Home's constellation, Zeno's header, Zeno's bubbles and the user's on the
// brand gradient, Zeno's thinking waves before each line, replies to tap
// along the bottom - the one Zeno would take lit in its gradient. Under
// some lines, a card: what Zeno can do, the Buying Agent's radar at work,
// and what Premium unlocks, with the price read from GET /pricing/plans.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors, ZoneGlowText;
import '../../../theme/motion.dart';
import '../../../widgets/chat_parts.dart';
import '../../../widgets/collapsing_screen_header.dart' show BrokaHeaderButton;
import '../../../widgets/constellation_background.dart';
import '../../../widgets/zeno_avatar.dart';
import '../../../widgets/zeno_streaming_text.dart';
import '../../buy_agent/presentation/widgets/agent_hud.dart' show AgentHoloBorder, AgentThinkingWave;
import '../../buy_agent/presentation/widgets/agent_motion.dart' show AgentEntrance, AgentOrb, AgentScanCard;
import '../../premium/data/premium_repository.dart';
import '../../premium/domain/premium.dart';
import '../zeno_intro.dart';
import '../zeno_session.dart';

class ZenoIntroChat extends StatefulWidget {
  const ZenoIntroChat({super.key, required this.session, required this.intro});

  final ZenoSession session;
  final ZenoIntro intro;

  @override
  State<ZenoIntroChat> createState() => _ZenoIntroChatState();
}

class _ZenoIntroChatState extends State<ZenoIntroChat> with SingleTickerProviderStateMixin {
  late final AnimationController _in =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final _reveal = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
  final _scroll = ScrollController();
  final _field = TextEditingController();

  /// Lines that have just arrived: they come in, and Zeno's are written
  /// out word by word - once, on the frame they first appear. Anything said
  /// before this was built is simply there.
  final Set<ZenoIntroMessage> _fresh = Set.identity();
  int _seen = 0;

  ZenoIntro get _intro => widget.intro;

  @override
  void initState() {
    super.initState();
    _intro.addListener(_onIntro);
    _seen = _intro.messages.length;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_in.isAnimating || _in.isCompleted) return;
    BrokaMotion.reduced(context) ? _in.value = 1 : _in.forward();
  }

  @override
  void didUpdateWidget(ZenoIntroChat old) {
    super.didUpdateWidget(old);
    if (!identical(old.intro, widget.intro)) {
      old.intro.removeListener(_onIntro);
      widget.intro.addListener(_onIntro);
      _fresh.clear();
      _seen = widget.intro.messages.length;
    }
  }

  @override
  void dispose() {
    _intro.removeListener(_onIntro);
    _reveal.dispose();
    _in.dispose();
    _scroll.dispose();
    _field.dispose();
    super.dispose();
  }

  void _onIntro() {
    if (!mounted) return;
    final messages = _intro.messages;
    setState(() {
      for (var i = _seen; i < messages.length; i++) {
        _fresh.add(messages[i]);
      }
    });
    if (messages.length != _seen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fresh.clear());
    }
    _seen = messages.length;
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (BrokaMotion.reduced(context)) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(end, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
      }
    });
  }

  void _submit([String? text]) {
    final q = (text ?? _field.text).trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    _field.clear();
    _intro.submit(q);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final messages = _intro.messages;
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: _in,
        builder: (context, child) => ClipPath(clipper: _CircleReveal(_reveal.value), child: child),
        child: ConstellationBackground(
          animate: !BrokaMotion.reduced(context),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.2,
                colors: [BrokaColors.neonPurple.withOpacity(0.16), Colors.transparent],
                stops: const [0.0, 0.6],
              ),
            ),
            child: SafeArea(
              child: Column(children: [
                _Header(session: session),
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: messages.length + (_intro.thinking ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == messages.length) {
                        return const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: AgentEntrance(
                            play: true,
                            fromUser: false,
                            child: AgentThinkingWave(avatar: true, padding: EdgeInsets.zero),
                          ),
                        );
                      }
                      final m = messages[i];
                      final fresh = _fresh.contains(m);
                      return AgentEntrance(
                        key: ObjectKey(m),
                        play: fresh,
                        fromUser: !m.fromZeno,
                        child: _Bubble(message: m, write: fresh, script: _intro.script, onGrow: _scrollDown),
                      );
                    },
                  ),
                ),
                _Answers(intro: _intro, field: _field, onSubmit: _submit),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A circle opening from the centre until it covers the screen.
class _CircleReveal extends CustomClipper<Path> {
  _CircleReveal(this.t);
  final double t;

  @override
  Path getClip(Size size) {
    final c = size.center(Offset.zero);
    final far = math.sqrt(c.dx * c.dx + c.dy * c.dy);
    return Path()..addOval(Rect.fromCircle(center: c, radius: 24 + (far - 24) * t));
  }

  @override
  bool shouldReclip(_CircleReveal old) => old.t != t;
}

/// Zeno's header, as on its chat: Zeno in its ring, its name, who it is -
/// and a way to mute it, and a way out.
class _Header extends StatelessWidget {
  const _Header({required this.session});

  final ZenoSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final muted = session.muted;
          final swahili = session.tour.script?.language == 'swahili';
          return Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 12, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.6))),
            ),
            child: Row(children: [
              const AgentOrb(size: 36),
              const SizedBox(width: 11),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  const ZoneGlowText('Meet Zeno',
                      gradient: kChatGradient, fontSize: 18, maxLines: 1, letterSpacing: 1.4),
                  const SizedBox(height: 3),
                  Row(children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: BrokaColors.neonGreen,
                        boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.7), blurRadius: 6)],
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(swahili ? 'Msaidizi binafsi mwenye akili' : 'Personal intelligent assistant',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(width: 8),
              BrokaHeaderButton(
                icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                active: !muted,
                tooltip: muted ? "Read Zeno's replies aloud" : 'Mute Zeno',
                onTap: () {
                  if (!muted) session.tourStopSpeaking();
                  session.toggleMute();
                },
              ),
              const SizedBox(width: 8),
              BrokaHeaderButton(
                key: const Key('zeno-intro-close'),
                icon: Icons.close_rounded,
                tooltip: 'Maybe later',
                onTap: session.tour.decline,
              ),
            ]),
          );
        },
      );
}

/// One line of the conversation - and, under Zeno's, its card.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.write, required this.script, this.onGrow});

  final ZenoIntroMessage message;
  final bool write;
  final ZenoIntroScript script;
  final VoidCallback? onGrow;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    if (!message.fromZeno) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: myBubbleDecoration(),
            child: Text(message.text,
                style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.45, fontWeight: FontWeight.w600)),
          ),
        ),
      );
    }
    final card = message.card;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const ZenoAvatar(size: 28),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: zenoBubbleDecoration(),
              child: ZenoStreamingText(
                message.text,
                key: ObjectKey(message),
                animate: write,
                onGrow: onGrow,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5, height: 1.5),
              ),
            ),
          ),
        ]),
        if (card != null)
          Padding(
            padding: const EdgeInsets.only(left: 36, top: 10),
            child: switch (card) {
              ZenoIntroCard.powers => _PowersCard(script: script),
              ZenoIntroCard.hunt => _HuntCard(captions: script.huntCaptions),
              ZenoIntroCard.premium => _PremiumCard(script: script),
            },
          ),
      ]),
    );
  }
}

/// What Zeno can do: a tile each, two to a row.
class _PowersCard extends StatelessWidget {
  const _PowersCard({required this.script});

  final ZenoIntroScript script;

  static const _icons = [
    Icons.travel_explore_rounded,
    Icons.radar_rounded,
    Icons.visibility_rounded,
    Icons.photo_camera_rounded,
    Icons.graphic_eq_rounded,
    Icons.insights_rounded,
  ];
  static const _tints = [
    BrokaColors.neonCyan,
    BrokaColors.neonPurple,
    BrokaColors.neonGreen,
    BrokaColors.neonPink,
    BrokaColors.neonBlue,
    BrokaColors.warning,
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final tile = (box.maxWidth - 8) / 2;
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (i, (title, line)) in script.powers.indexed)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: BrokaMotion.of(context, Duration(milliseconds: 500 + 110 * i)),
              curve: Interval((0.12 * i).clamp(0.0, 0.7), 1, curve: Curves.easeOutBack),
              builder: (_, v, child) => Opacity(
                opacity: v.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.7 + 0.3 * v, child: child),
              ),
              child: Container(
                width: tile,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: BrokaColors.bgCard.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _tints[i % _tints.length].withOpacity(0.4)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _tints[i % _tints.length].withOpacity(0.16),
                    ),
                    child: Icon(_icons[i % _icons.length], size: 16, color: _tints[i % _tints.length]),
                  ),
                  const SizedBox(height: 8),
                  Text(title,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(line, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
                ]),
              ),
            ),
        ]);
      });
}

/// The Buying Agent at work: its radar sweeping, saying in turn what it
/// does. A show, not a search - nothing here claims a result.
class _HuntCard extends StatefulWidget {
  const _HuntCard({required this.captions});

  final List<String> captions;

  @override
  State<_HuntCard> createState() => _HuntCardState();
}

class _HuntCardState extends State<_HuntCard> {
  int _step = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Through the captions once, then it rests on the last: recommending.
    _timer = Timer.periodic(const Duration(milliseconds: 1700), (t) {
      if (!mounted || _step >= widget.captions.length - 1) {
        t.cancel();
        return;
      }
      setState(() => _step++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AgentScanCard(
        caption: widget.captions[_step],
        step: _step,
        steps: widget.captions.length,
        padding: EdgeInsets.zero,
      );
}

/// What Premium unlocks, and what the cheapest plan costs - from the plans
/// themselves, or no price at all if they can't be read.
class _PremiumCard extends StatefulWidget {
  const _PremiumCard({required this.script});

  final ZenoIntroScript script;

  @override
  State<_PremiumCard> createState() => _PremiumCardState();
}

class _PremiumCardState extends State<_PremiumCard> {
  PremiumPlan? _from;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await premiumRepository.plans();
    if (!mounted || r is! Success<List<PremiumPlan>>) return;
    final paid = r.data.where((p) => p.monthlyPrice > 0).toList()
      ..sort((a, b) => a.monthlyPrice.compareTo(b.monthlyPrice));
    if (paid.isNotEmpty) setState(() => _from = paid.first);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.script;
    final from = _from;
    return AgentHoloBorder(
      live: true,
      borderRadius: BorderRadius.circular(18),
      glow: 0.3,
      child: Container(
        key: const Key('zeno-intro-premium'),
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xF51A1040), Color(0xF50E1B3D)],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
                boxShadow: [BrokaColors.glowGold],
              ),
              child: const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => const LinearGradient(colors: BrokaColors.brandGradient).createShader(r),
                child: Text(s.premiumTitle,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          for (final unlock in s.premiumUnlocks)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.check_circle_rounded, size: 16, color: BrokaColors.success),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(unlock,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, height: 1.35)),
                ),
              ]),
            ),
          if (from != null) ...[
            const SizedBox(height: 4),
            Text(s.priceLine(from.name, from.monthlyPrice),
                key: const Key('zeno-intro-price'),
                style: const TextStyle(color: BrokaColors.neonCyan, fontSize: 13, fontWeight: FontWeight.w800)),
          ],
          const SizedBox(height: 4),
          Text(s.freeNote, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        ]),
      ),
    );
  }
}

/// Along the bottom: the replies to tap - or, when Zeno has asked what the
/// user would love to buy, a field for it and ideas.
class _Answers extends StatelessWidget {
  const _Answers({required this.intro, required this.field, required this.onSubmit});

  final ZenoIntro intro;
  final TextEditingController field;
  final void Function([String? text]) onSubmit;

  @override
  Widget build(BuildContext context) {
    final replies = intro.replies;
    final asking = intro.asking;
    final Widget child;
    if (replies.isEmpty && !asking) {
      child = const SizedBox(key: ValueKey('none'), width: double.infinity);
    } else {
      child = Padding(
        key: ValueKey(intro.beat?.id),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (asking) ...[
            Container(
              padding: const EdgeInsets.only(left: 16, right: 4),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.92),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.6), width: 1.4),
                boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 14)],
              ),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('zeno-intro-field'),
                    controller: field,
                    autofocus: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => onSubmit(),
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15),
                    cursorColor: BrokaColors.neonBlue,
                    decoration: InputDecoration(
                      hintText: intro.script.askHint,
                      hintStyle: const TextStyle(color: BrokaColors.textMid),
                      filled: false,
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Find it',
                  onPressed: onSubmit,
                  icon: const Icon(Icons.travel_explore_rounded, color: BrokaColors.neonCyan, size: 22),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final (emoji, idea) in intro.script.ideas)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Chip(label: '$emoji $idea', onTap: () => onSubmit(idea)),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in replies)
                _Chip(label: r.label, primary: r.primary, onTap: () => intro.choose(r)),
            ],
          ),
        ]),
      );
    }
    return AnimatedSwitcher(
      duration: BrokaMotion.of(context, const Duration(milliseconds: 320)),
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SizeTransition(sizeFactor: a, axisAlignment: 1, child: c),
      ),
      child: child,
    );
  }
}

/// A reply: Home's chip, or - for the one Zeno would take - its gradient.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.primary = false});

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
              decoration: primary
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      gradient: const LinearGradient(colors: kChatGradient),
                      boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.4), blurRadius: 14)],
                    )
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      color: BrokaColors.bgCard.withOpacity(0.9),
                      border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45)),
                    ),
              child: Text(label,
                  style: TextStyle(
                      color: primary ? Colors.white : BrokaColors.textHigh,
                      fontSize: 13,
                      fontWeight: primary ? FontWeight.w800 : FontWeight.w600)),
            ),
          ),
        ),
      );
}
