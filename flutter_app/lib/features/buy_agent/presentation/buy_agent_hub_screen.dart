// lib/features/buy_agent/presentation/buy_agent_hub_screen.dart
//
// The full Buying Agent experience (Design v2 §14-15, §23) - the sheet
// (buy_agent_sheet.dart) stays as the quick 3-field form reachable from
// Home's Quick Access row; this is the fuller screen the same doc asks
// for, reached from the Home hero card's CTA.
//
// Flow: type or pick a template -> Zeno parses it (parse-intent) -> a
// confirmation card shows what was understood before anything runs (§15:
// "user confirmation activates the action" - the confirmation step is
// what makes an imperfect parse safe) -> SEARCH_PRODUCTS runs through the
// same action engine and ranking as everything else -> results, with an
// option to turn the same search into a standing CREATE_BUYING_REQUEST so
// Zeno keeps watching after the user leaves.
//
// Match card labels are derived from real fields returned alongside each
// match (seller_verified, distance_km, price vs the stated budget) -
// never a fabricated match percentage (§23: "do not invent match
// percentages unless a real scoring model exists" - the ranking score
// exists but isn't a calibrated probability, so it drives order, not a
// displayed number).
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../../../widgets/zeno_avatar.dart';
import '../../../widgets/product_card.dart';
import '../data/repositories/buy_agent_repository.dart';
import '../domain/models/buy_agent_request.dart';
import '../../listings/domain/models/listing.dart';

enum _HubStage { input, confirming, searching, results }

const _quickTemplates = <String, String>{
  'Find a car': 'Find me a car',
  'Find a phone': 'Find me a phone',
  'Find a laptop': 'Find me a laptop',
  'Find property': 'Find me a property',
  'Find furniture': 'Find me furniture',
  'Find farm equipment': 'Find me farm equipment',
};

class BuyAgentHubScreen extends StatefulWidget {
  // Optional pre-filled query (redesign-guide audit) - lets Home's search
  // hand off a natural-language buying request straight into the Hub
  // instead of the buyer having to retype it (Design v2 §4: "Natural
  // buying request -> Zeno intent extraction -> structured Buying Agent
  // action").
  final String? initialQuery;
  const BuyAgentHubScreen({super.key, this.initialQuery});
  @override
  State<BuyAgentHubScreen> createState() => _BuyAgentHubScreenState();
}

class _BuyAgentHubScreenState extends State<BuyAgentHubScreen> {
  final _textController = TextEditingController();
  final _refineController = TextEditingController();
  _HubStage _stage = _HubStage.input;
  Map<String, dynamic>? _parsedIntent;
  List<dynamic> _matches = const [];
  int _resultCount = 0;
  BuyAgentRequest? _activeRequest;
  bool _busy = false;
  bool _refining = false;
  bool _watching = false;
  bool _cancelling = false;
  // FIX (ChatGPT-review audit, 2026-08-15): lets the buyer opt into Zeno
  // auto-messaging a seller the instant a match is found, instead of just
  // being notified and reviewing matches themselves. Defaults false (the
  // safe choice, matching negotiation_authorized's own column default) -
  // Design v2 §24 requires genuine pre-authorization for autonomous
  // negotiation, so this can't default to true.
  bool _autoNegotiate = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadActiveRequest();
    final initial = widget.initialQuery?.trim();
    if (initial != null && initial.isNotEmpty) {
      _textController.text = initial;
      _understand();
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _refineController.dispose();
    super.dispose();
  }

  Future<void> _loadActiveRequest() async {
    final result = await buyAgentRepository.getActive();
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() => _activeRequest = data),
      onFailure: (_, __) {},
    );
  }

  Future<void> _understand() async {
    final text = _textController.text.trim();
    if (text.length < 3) {
      setState(() => _error = 'Tell me a bit more about what you need.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final result = await buyAgentRepository.parseIntent(text);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _parsedIntent = data;
        _stage = _HubStage.confirming;
        _busy = false;
      }),
      onFailure: (msg, __) => setState(() {
        _error = 'Couldn\'t understand that just now — try rephrasing, or use a template below.';
        _busy = false;
      }),
    );
  }

  Future<void> _confirmAndSearch() async {
    setState(() { _stage = _HubStage.searching; _busy = true; _error = null; });
    final intent = _parsedIntent!;
    final result = await buyAgentRepository.executeAction(
      {
        'action': 'SEARCH_PRODUCTS',
        'optimization_code': 'BALANCED_MATCH',
        'parameters': {
          'query': intent['query'],
          'category': intent['category'],
          'subcategory': intent['subcategory'],
          'min_price': intent['min_price'],
          'max_price': intent['max_price'],
          'location': intent['location'],
          'max_distance_km': intent['max_distance_km'],
          'condition': intent['condition'],
          'attributes': intent['attributes'],
        },
      },
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) {
        if (data['status'] == 'SUCCESS') {
          setState(() {
            _matches = data['matches'] as List? ?? [];
            _resultCount = data['result_count'] as int? ?? _matches.length;
            _stage = _HubStage.results;
            _busy = false;
          });
        } else {
          setState(() {
            _error = data['message'] as String? ?? 'That search didn\'t go through — try again.';
            _stage = _HubStage.confirming;
            _busy = false;
          });
        }
      },
      onFailure: (msg, __) => setState(() {
        _error = msg;
        _stage = _HubStage.confirming;
        _busy = false;
      }),
    );
  }

  Future<void> _keepWatching() async {
    final intent = _parsedIntent!;
    if (intent['category'] == null || intent['max_price'] == null) {
      setState(() => _error = 'Tell me a category and a budget so I can keep watching for this.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final result = await buyAgentRepository.executeAction(
      {
        'action': 'CREATE_BUYING_REQUEST',
        'optimization_code': 'BALANCED_MATCH',
        'parameters': {
          'category': intent['category'],
          'subcategory': intent['subcategory'],
          'query': intent['query'],
          'max_price': intent['max_price'],
          'min_price': intent['min_price'],
          'location': intent['location'],
          'max_distance_km': intent['max_distance_km'],
          'condition': intent['condition'],
          'attributes': intent['attributes'],
          'must_have_features': const [],
          'negotiation_authorized': _autoNegotiate,
        },
      },
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) {
        if (data['status'] == 'SUCCESS') {
          setState(() {
            _watching = true;
            _busy = false;
            _activeRequest = BuyAgentRequest.fromJson(data['request'] as Map<String, dynamic>);
          });
        } else {
          setState(() {
            _error = data['message'] as String? ?? 'Couldn\'t set that up — try again.';
            _busy = false;
          });
        }
      },
      onFailure: (msg, __) => setState(() { _error = msg; _busy = false; }),
    );
  }

  void _editSearch() => setState(() => _stage = _HubStage.input);

  /// CANCEL_REQUEST (redesign-guide audit). Before this existed, a buyer
  /// who created a standing request had no way to ever get rid of it from
  /// the app, and with BUY_AGENT_MAX_ACTIVE defaulting to 1, that meant no
  /// way to ever start a different search once one was active.
  Future<void> _cancelRequest() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Cancel this request?', style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        content: const Text("Zeno will stop watching for matches on this one.",
            style: TextStyle(color: BrokaColors.textMid, fontSize: 13.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel request', style: TextStyle(color: BrokaColors.danger))),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _cancelling = true);
    final result = await buyAgentRepository.cancelRequest();
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _cancelling = false;
        if (data['status'] == 'SUCCESS') {
          _activeRequest = null;
          _watching = false;
        } else {
          _error = data['message'] as String? ?? "Couldn't cancel that just now.";
        }
      }),
      onFailure: (msg, __) => setState(() { _cancelling = false; _error = msg; }),
    );
  }

  /// REFINE_SEARCH (redesign-guide audit, Design v2 §21: "Zeno must
  /// understand that 'it' refers to the active request"). Sends the
  /// follow-up text alongside the filters the current results were built
  /// from so the model returns a merged filter set, then re-runs the
  /// search exactly like _confirmAndSearch - a refinement IS a new search,
  /// just one whose parameters already carry the prior constraints.
  Future<void> _refineSearch() async {
    final text = _refineController.text.trim();
    if (text.isEmpty) return;
    setState(() { _refining = true; _error = null; });
    final currentFilters = {
      'query': _parsedIntent?['query'],
      'category': _parsedIntent?['category'],
      'subcategory': _parsedIntent?['subcategory'],
      'min_price': _parsedIntent?['min_price'],
      'max_price': _parsedIntent?['max_price'],
      'location': _parsedIntent?['location'],
      'max_distance_km': _parsedIntent?['max_distance_km'],
      'condition': _parsedIntent?['condition'],
      'attributes': _parsedIntent?['attributes'],
    };
    final parseResult = await buyAgentRepository.parseIntent(text, existingFilters: currentFilters);
    if (!mounted) return;
    if (parseResult is Failure) {
      setState(() { _refining = false; _error = "Couldn't refine that just now — try again."; });
      return;
    }
    final merged = (parseResult as Success).data;
    final result = await buyAgentRepository.executeAction(
      {
        'action': 'REFINE_SEARCH',
        'optimization_code': 'BALANCED_MATCH',
        'parameters': {
          'query': merged['query'],
          'category': merged['category'],
          'subcategory': merged['subcategory'],
          'min_price': merged['min_price'],
          'max_price': merged['max_price'],
          'location': merged['location'],
          'max_distance_km': merged['max_distance_km'],
          'condition': merged['condition'],
          'attributes': merged['attributes'],
        },
      },
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) {
        if (data['status'] == 'SUCCESS') {
          setState(() {
            _parsedIntent = merged;
            _matches = data['matches'] as List? ?? [];
            _resultCount = data['result_count'] as int? ?? _matches.length;
            _refining = false;
            _refineController.clear();
          });
        } else {
          setState(() {
            _refining = false;
            _error = data['message'] as String? ?? "That refinement didn't go through — try again.";
          });
        }
      },
      onFailure: (msg, __) => setState(() { _refining = false; _error = msg; }),
    );
  }

  /// START_NEGOTIATION (Design v2 §24) - shows the "shall I start the
  /// negotiation?" confirmation the doc requires before ever calling the
  /// action, since Zeno must not negotiate automatically.
  Future<void> _startNegotiation(BrokaListing listing) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Start negotiating?', style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        content: Text(
          "I'll reach out to the seller of \"${listing.name}\" on your behalf and open a conversation. "
          "You'll see everything they say and can take over anytime.",
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not yet', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, start it', style: TextStyle(color: BrokaColors.neonBlue))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await buyAgentRepository.startNegotiation(listing.id);
    if (!mounted) return;
    result.fold(
      onSuccess: (data) {
        if (data['status'] == 'SUCCESS') {
          Navigator.pushNamed(context, '/negotiate', arguments: {'listingId': listing.id});
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(data['message'] as String? ?? "Couldn't start that negotiation just now."),
          ));
        }
      },
      onFailure: (msg, __) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg))),
    );
  }

  void _useTemplate(String text) {
    _textController.text = text;
    _textController.selection = TextSelection.collapsed(offset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        title: const Text('Buying Agent', style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: switch (_stage) {
            _HubStage.input => _buildInputStage(),
            _HubStage.confirming => _buildConfirmingStage(),
            _HubStage.searching => _buildSearchingStage(),
            _HubStage.results => _buildResultsStage(),
          },
        ),
      ),
    );
  }

  Widget _buildInputStage() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(
        child: Column(children: [
          const ZenoAvatar(size: 88, style: ZenoAvatarStyle.hero, glow: true),
          const SizedBox(height: 14),
          const Text("Tell me what you're looking for.",
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
          const Text("I'll find it for you.",
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ]),
      ),
      const SizedBox(height: 22),
      Container(
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: TextField(
          controller: _textController,
          maxLines: 3,
          minLines: 2,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.all(14),
            border: InputBorder.none,
            hintText: 'Find me a used Toyota Prado under KES 3.5M around Ugunja',
            hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 13),
          ),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5)),
      ],
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _busy ? null : _understand,
          style: ElevatedButton.styleFrom(
            backgroundColor: BrokaColors.neonBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          child: _busy
              ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('✨ Find it for me', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        ),
      ),
      const SizedBox(height: 20),
      const Text('QUICK START', style: TextStyle(color: BrokaColors.textLow, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: _quickTemplates.entries.map((e) => GestureDetector(
          onTap: () => _useTemplate(e.value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Text(e.key, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
          ),
        )).toList(),
      ),
      if (_activeRequest != null) ...[
        const SizedBox(height: 24),
        const Text('ACTIVE REQUEST', style: TextStyle(color: BrokaColors.textLow, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        const SizedBox(height: 10),
        _activeRequestCard(_activeRequest!),
      ],
    ]);
  }

  Widget _activeRequestCard(BuyAgentRequest req) {
    final matched = req.status == 'matched';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Row(children: [
        const ZenoAvatar(size: 34, glow: true),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(req.category, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Under KES ${req.maxPrice.toStringAsFixed(0)}',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
            const SizedBox(height: 4),
            Text(
              matched
                  ? '${req.matchCount} match${req.matchCount == 1 ? '' : 'es'} found!'
                  : 'Zeno is still searching…',
              style: TextStyle(color: matched ? BrokaColors.success : BrokaColors.textLow, fontSize: 11.5),
            ),
          ]),
        ),
        // FIX (redesign-guide audit): previously there was no way to cancel
        // a standing request from anywhere in the app - with
        // BUY_AGENT_MAX_ACTIVE defaulting to 1, that permanently blocked a
        // buyer from ever starting a different search once one was active.
        _cancelling
            ? const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.textLow))
            : IconButton(
                onPressed: _cancelRequest,
                icon: const Icon(Icons.close_rounded, color: BrokaColors.textLow, size: 20),
                tooltip: 'Cancel request',
                visualDensity: VisualDensity.compact,
              ),
      ]),
    );
  }

  Widget _buildConfirmingStage() {
    final intent = _parsedIntent ?? {};
    final rows = <Widget>[];
    void addRow(String emoji, String? value) {
      if (value == null || value.toString().trim().isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('$emoji  $value', style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5)),
      ));
    }
    addRow('🔎', intent['query'] as String?);
    addRow('📦', intent['subcategory'] != null ? '${intent['category']} · ${intent['subcategory']}' : intent['category'] as String?);
    final min = intent['min_price'], max = intent['max_price'];
    if (min != null && max != null) {
      addRow('💰', 'KES ${_fmt(min)} – ${_fmt(max)}');
    } else if (max != null) {
      addRow('💰', 'Up to KES ${_fmt(max)}');
    }
    addRow('📍', intent['location'] as String?);
    if (intent['max_distance_km'] != null) addRow('📏', 'Within ${_fmt(intent['max_distance_km'])} km');
    addRow('✨', intent['condition'] as String?);
    final attrs = (intent['attributes'] as Map?) ?? {};
    for (final entry in attrs.entries) {
      addRow('•', '${entry.key}: ${entry.value}');
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const ZenoAvatar(size: 40, glow: true),
        const SizedBox(width: 10),
        const Expanded(child: Text('Here\'s what I understood:',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 15.5, fontWeight: FontWeight.bold))),
      ]),
      const SizedBox(height: 16),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.3)),
        ),
        child: rows.isEmpty
            ? const Text("I couldn't pick out specific details — I'll search broadly based on your words.",
                style: TextStyle(color: BrokaColors.textMid, fontSize: 13.5))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5)),
      ],
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : _editSearch,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: BrokaColors.border),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Edit', style: TextStyle(color: BrokaColors.textMid, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: ElevatedButton(
            onPressed: _busy ? null : _confirmAndSearch,
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: const Text('Find matches', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
    ]);
  }

  Widget _buildSearchingStage() {
    return SizedBox(
      height: 400,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ZenoAvatar(size: 72, style: ZenoAvatarStyle.hero, glow: true),
          const SizedBox(height: 18),
          const CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.neonBlue),
          const SizedBox(height: 14),
          const Text('Zeno is searching Broka…', style: TextStyle(color: BrokaColors.textMid, fontSize: 13.5)),
        ]),
      ),
    );
  }

  Widget _buildResultsStage() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text('$_resultCount result${_resultCount == 1 ? '' : 's'} found',
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        TextButton(
          onPressed: _editSearch,
          child: const Text('New search', style: TextStyle(color: BrokaColors.neonBlue, fontSize: 12.5)),
        ),
      ]),
      const SizedBox(height: 4),
      if (!_watching)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // FIX (ChatGPT-review audit, 2026-08-15): previously there was
            // no way for a buyer to ever authorize autonomous negotiation
            // at all - the backend column existed but nothing could set
            // it. Off by default; the buyer has to actively opt in.
            InkWell(
              onTap: () => setState(() => _autoNegotiate = !_autoNegotiate),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Checkbox(
                    value: _autoNegotiate,
                    onChanged: (v) => setState(() => _autoNegotiate = v ?? false),
                    activeColor: BrokaColors.neonBlue,
                    visualDensity: VisualDensity.compact,
                  ),
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        "Let Zeno message the seller for me automatically when it finds a match "
                        "(otherwise I'll review each match and start the conversation myself)",
                        style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _busy ? null : _keepWatching,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: BrokaColors.neonBlue.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _busy
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.neonBlue))
                    : const Text('👀  Keep Zeno watching for this', style: TextStyle(color: BrokaColors.neonBlue, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ),
          ]),
        )
      else
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            _autoNegotiate
                ? '✓ Zeno will message sellers automatically when new matches appear.'
                : '✓ Zeno will notify you when new matches appear.',
            style: const TextStyle(color: BrokaColors.success, fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      if (_error != null) ...[
        Text(_error!, style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5)),
        const SizedBox(height: 10),
      ],
      if (_matches.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: Text('No listings match that yet — try widening your search, or keep Zeno watching for when something appears.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 13), textAlign: TextAlign.center)),
        )
      else ...[
        ..._matches.map((m) => _matchCard(m as Map<String, dynamic>)),
        const SizedBox(height: 4),
        // REFINE_SEARCH (redesign-guide audit, Design v2 §21) - a
        // conversational follow-up on the results just shown, rather than
        // starting over from the input stage.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _refineController,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Refine this — e.g. "only 2018 or newer"',
                  hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 12.5),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onSubmitted: (_) => _refining ? null : _refineSearch(),
              ),
            ),
            _refining
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.neonBlue)),
                  )
                : IconButton(
                    onPressed: _refineSearch,
                    icon: const Icon(Icons.arrow_upward_rounded, color: BrokaColors.neonBlue),
                  ),
          ]),
        ),
      ],
    ]);
  }

  Widget _matchCard(Map<String, dynamic> match) {
    final listing = BrokaListing.fromJson(match);
    final maxPrice = (_parsedIntent?['max_price'] as num?)?.toDouble();
    final labels = <String>[];
    if (match['seller_verified'] == true) labels.add('Trusted seller');
    final distanceKm = (match['distance_km'] as num?)?.toDouble();
    if (distanceKm != null && distanceKm <= 20) labels.add('Nearby');
    if (maxPrice != null && listing.price <= maxPrice * 0.9) labels.add('Budget match');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 210,
          child: ProductCard(
            item: listing,
            onTap: () => Navigator.pushNamed(context, '/product', arguments: {'listingId': listing.id}),
          ),
        ),
        if (labels.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, children: labels.map((l) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: BrokaColors.success.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: BrokaColors.success.withOpacity(0.4)),
              ),
              child: Text(l, style: const TextStyle(color: BrokaColors.success, fontSize: 10.5, fontWeight: FontWeight.w600)),
            )).toList()),
          ),
        // START_NEGOTIATION (redesign-guide audit, Design v2 §24) - lets
        // the buyer act on a specific match right from the results list,
        // instead of the Hub only ever being able to search + watch.
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _startNegotiation(listing),
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15, color: BrokaColors.neonBlue),
              label: const Text('Ask Zeno to negotiate', style: TextStyle(color: BrokaColors.neonBlue, fontSize: 12.5, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: BrokaColors.neonBlue.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  String _fmt(dynamic n) {
    if (n == null) return '';
    final d = (n as num).toDouble();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }
}
