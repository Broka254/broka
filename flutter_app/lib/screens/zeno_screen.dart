// BROKA - Zeno AI Assistant
// Powered by Gemini 2.0 Flash. Supports English, Kiswahili, Dholuo, Kikuyu, Luganda, Sheng.
import 'package:flutter/material.dart';
import '../services/broka_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../main.dart';
import '../widgets/chat_ambient_background.dart';
import '../services/api_service.dart';
import '../models/models.dart';

// ── Language definitions ──────────────────────────────────────────────────────
class _Lang {
  final String key;
  final String name;
  final String flag;
  final String ttsLocale;
  const _Lang(this.key, this.name, this.flag, this.ttsLocale);
}

const _languages = [
  _Lang('english', 'English',   '🇬🇧', 'en-KE'),
  _Lang('swahili', 'Kiswahili', '🇰🇪', 'sw-KE'),
  _Lang('luo',     'Dholuo',    '🟡',  'en-KE'),
  _Lang('kikuyu',  'Kikuyu',    '🟤',  'en-KE'),
  _Lang('luganda', 'Luganda',   '🇺🇬', 'en-UG'),
  _Lang('sheng',   'Sheng',     '🔥',  'en-KE'),
];

_Lang _langByKey(String key) =>
    _languages.firstWhere((l) => l.key == key, orElse: () => _languages[0]);

class ZenoScreen extends StatefulWidget {
  const ZenoScreen({super.key});
  @override
  State<ZenoScreen> createState() => _ZenoScreenState();
}

class _ZenoScreenState extends State<ZenoScreen>
    with SingleTickerProviderStateMixin {
  final _msgCtrl    = TextEditingController();

  // Composer state - mirrors negotiation_screen.dart so both conversation
  // surfaces behave identically.
  final FocusNode _composerFocus = FocusNode();
  bool _hasDraft = false;
  bool _composerFocused = false;
  final _scrollCtrl = ScrollController();
  bool _typing      = false;
  List<Message> _messages = [];
  List<Map<String, String>> _history = [];

  String get _langKey => ApiService.currentUserLanguage;

  final _tts = BrokaTts.instance;
  bool _ttsEnabled = true;
  bool _speaking   = false;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _listening    = false;

  late AnimationController _pulseCtrl;

  String get _firstName {
    final n = ApiService.currentUserName;
    return n != null && n.isNotEmpty ? n.split(' ').first : '';
  }

  final _suggestions = const [
    ('🚗', 'Is KES 800K fair for a Toyota Axio 2012?'),
    ('📊', 'What\'s the market like for phones right now?'),
    ('🔍', 'How do I spot a fake listing?'),
    ('🤝', 'Tips to close a deal faster'),
    ('🏠', 'How does BROKA escrow work?'),
    ('📍', 'Why does location matter in a deal?'),
  ];

  @override
  void initState() {
    super.initState();
    _tts.onFallback = () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Using offline voice — Zeno\'s usual voice is unavailable right now.'),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
    };
    _initTts();
    _initStt();
    _addWelcome();
    // Only rebuild on the empty/non-empty boundary, not per keystroke.
    _msgCtrl.addListener(() {
      final has = _msgCtrl.text.trim().isNotEmpty;
      if (has != _hasDraft && mounted) setState(() => _hasDraft = has);
    });
    _composerFocus.addListener(() {
      if (mounted && _composerFocus.hasFocus != _composerFocused) {
        setState(() => _composerFocused = _composerFocus.hasFocus);
      }
    });
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _composerFocus.dispose();
    _scrollCtrl.dispose();
    _pulseCtrl.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initTts() async => await _tts.init();

  Future<void> _initStt() async {
    _sttAvailable = await _speech.initialize();
    if (mounted) setState(() {});
  }

  void _addWelcome() {
    final lang = _langByKey(_langKey);
    final greet = _firstName.isNotEmpty ? ', $_firstName' : '';
    final welcomeMsg = switch (_langKey) {
      'swahili' => 'Habari$greet! Mimi ni Zeno, mshauri wako wa biashara wa BROKA. Ninaweza kukusaidia kutathmini bei, kugundua udanganyifu, au kupanga mkakati wa mazungumzo. Niulize chochote! 🤝',
      'luo'     => 'Misawa$greet! An Zeno, jakony mar ohala mar BROKA. Anyalo konyi nyiso nengo maber, neno wach miriambo, kata loso hera. Penj gimoro amora! 🤝',
      'kikuyu'  => 'Wĩmwega$greet! Nĩ niĩ Zeno, mũteithia waku wa biashara wa BROKA. Ngũkuteithia gũthagania thaara, gwĩkira mahinda ma mũrũgamo, kana gũtheria wĩhĩo. Ĩũlĩria kĩndũ kĩothe! 🤝',
      _         => 'Hello$greet! I\'m Zeno, your BROKA marketplace AI assistant. I can help you evaluate prices, spot suspicious listings, plan your negotiation strategy, and analyse market trends. Ask me anything! 🤝',
    };
    _messages.add(Message(role: 'broker', content: welcomeMsg));
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _msgCtrl.text).trim();
    if (text.isEmpty || _typing) return;
    _msgCtrl.clear();
    setState(() {
      _messages.add(Message(role: 'user', content: text));
      _typing = true;
    });
    _scrollDown();
    _history.add({'role': 'user', 'content': text});
    try {
      final reply = await ApiService.zenoChat(
        message: text,
        history: _history,
        language: _langKey,
      );
      if (mounted) {
        _history.add({'role': 'assistant', 'content': reply});
        setState(() {
          _messages.add(Message(role: 'broker', content: reply));
          _typing = false;
        });
        if (_ttsEnabled) _speak(reply);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(Message(role: 'broker',
              content: '⚠️ Zeno is unavailable right now. Please try again shortly.'));
          _typing = false;
        });
      }
    }
    _scrollDown();
  }

  Future<void> _speak(String text) async {
    if (!_ttsEnabled) return;
    setState(() => _speaking = true);
    final lang = _langByKey(_langKey);
    await _tts.speak(text, language: _langKey);
    if (mounted) setState(() => _speaking = false);
  }

  void _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_sttAvailable) return;
    setState(() => _listening = true);
    _speech.listen(
      onResult: (r) {
        if (r.finalResult) {
          setState(() { _listening = false; _msgCtrl.text = r.recognizedWords; });
        }
      },
      localeId: _langByKey(_langKey).ttsLocale,
      cancelOnError: true,
    );
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // Same constellation field as the splash screen and the direct-chat
      // thread, at slightly higher intensity: this is Zeno's own surface,
      // it carries less dense content than a buyer/seller thread, and the
      // visual continuity with "BOOTING ZENO" on the splash is the point.
      body: ChatAmbientBackground(
        intensity: 1.0,
        child: Column(children: [
          _buildHeader(),
          Expanded(child: _buildMessages()),
          if (_typing) _buildTypingIndicator(),
          if (_messages.length <= 1) _buildSuggestions(),
          _buildInputBar(),
        ]),
      ),
    );
  }

  Widget _buildHeader() => SafeArea(
    bottom: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.88),
        border: const Border(bottom: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                color: BrokaColors.textMid, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, __) => Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              boxShadow: [BoxShadow(
                color: BrokaColors.gold.withOpacity(0.3 + 0.3 * _pulseCtrl.value),
                blurRadius: 12 + 8 * _pulseCtrl.value,
              )],
            ),
            child: const Icon(Icons.auto_awesome_rounded,
                color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Zeno', style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
          Text('AI Market Assistant · ${_langByKey(_langKey).flag} ${_langByKey(_langKey).name}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ])),
        // TTS toggle
        GestureDetector(
          onTap: () { _tts.stop(); setState(() => _ttsEnabled = !_ttsEnabled); },
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _ttsEnabled
                  ? BrokaColors.gold.withOpacity(0.12)
                  : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _ttsEnabled
                  ? BrokaColors.gold.withOpacity(0.5) : BrokaColors.border),
            ),
            child: Icon(_ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: _ttsEnabled ? BrokaColors.gold : BrokaColors.textLow, size: 18),
          ),
        ),
      ]),
    ),
  );

  Widget _buildMessages() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    itemCount: _messages.length,
    itemBuilder: (_, i) => _ZenoBubble(message: _messages[i]),
  );

  Widget _buildTypingIndicator() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.neonBlue]),
        ),
        child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 14),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _dot(0), const SizedBox(width: 4),
          _dot(200), const SizedBox(width: 4),
          _dot(400),
        ]),
      ),
    ]),
  );

  Widget _dot(int delayMs) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0.3, end: 1.0),
    duration: const Duration(milliseconds: 600),
    curve: Curves.easeInOut,
    builder: (_, v, __) => Opacity(
      opacity: v,
      child: Container(width: 6, height: 6,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, color: BrokaColors.gold)),
    ),
  );

  Widget _buildSuggestions() => Container(
    height: 80,
    color: BrokaColors.bgMid,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      children: _suggestions.map((s) => GestureDetector(
        onTap: () => _send(s.$2),
        child: Container(
          margin: const EdgeInsets.only(right: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(s.$1, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Text(s.$2, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 12)),
          ]),
        ),
      )).toList(),
    ),
  );

  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.92),
        border: const Border(top: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _listening
                      ? BrokaColors.danger.withOpacity(0.6)
                      : (_composerFocused
                          ? BrokaColors.gold.withOpacity(0.55)
                          : BrokaColors.border),
                  width: (_listening || _composerFocused) ? 1.4 : 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 13, 2, 13),
                    child: Icon(Icons.auto_awesome_rounded,
                        size: 17, color: BrokaColors.gold),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      focusNode: _composerFocus,
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontSize: 15, height: 1.35),
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      cursorColor: BrokaColors.gold,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Ask Zeno anything',
                        hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 15),
                        border: InputBorder.none,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 6, vertical: 13),
                      ),
                    ),
                  ),
                  if (_sttAvailable && !_hasDraft)
                    InkResponse(
                      onTap: _toggleListening,
                      radius: 22,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 11, 12, 11),
                        child: Icon(
                          _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                          size: 22,
                          color: _listening ? BrokaColors.danger : BrokaColors.textMid,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedScale(
            scale: (_hasDraft || _typing) ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutBack,
            child: AnimatedOpacity(
              opacity: (_hasDraft || _typing) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 140),
              child: GestureDetector(
                onTap: (_typing || !_hasDraft) ? null : () => _send(),
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [BrokaColors.gold, BrokaColors.neonBlue],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: BrokaColors.gold.withOpacity(0.35),
                        blurRadius: 14, spreadRadius: 1),
                    ],
                  ),
                  child: _typing
                      ? const Center(
                          child: SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white)))
                      : const Icon(Icons.arrow_upward_rounded,
                          color: Colors.white, size: 21),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// ── Zeno Chat Bubble ─────────────────────────────────────────────────────────
class _ZenoBubble extends StatelessWidget {
  final Message message;
  const _ZenoBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isAI = message.isBroker;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isAI ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (isAI) ...[
            Container(
              width: 30, height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 14),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.82),
              decoration: BoxDecoration(
                gradient: isAI
                    ? LinearGradient(colors: [
                        BrokaColors.gold.withOpacity(0.10),
                        BrokaColors.bgCard,
                      ])
                    : const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.goldDim]),
                borderRadius: isAI
                    ? const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(14),
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14))
                    : const BorderRadius.only(
                        topLeft: Radius.circular(14),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14)),
                border: Border.all(color: isAI
                    ? BrokaColors.gold.withOpacity(0.3)
                    : BrokaColors.gold.withOpacity(0.4)),
              ),
              child: Text(message.content,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 14, height: 1.5)),
            ),
          ),
        ],
      ),
    );
  }
}
