// Zeno listing an item from its photo (2026-10-08) - "I only take the
// photo; Zeno does the rest." The app's side of backend
// api/domains/zeno_assistant/autolist.py.
//
// Opened from the sell wizard's Photos step once a photo is taken. One
// conversation, in the order a seller would tell a broker about an item:
//   1. Zeno looks at the first photo and fills the listing in - title,
//      where it is filed, condition, details, description - shown as the
//      card buyers will see, and asks what the photo can't show. The
//      seller answers or corrects in their own words ("it's the 256 GB
//      one"), and the card changes with every answer.
//   2. "Looks right" - Zeno prices it: a fair range and the one number to
//      ask, on similar live BROKA listings for a plan with price checks,
//      or as an estimate (and says so) on any other, with Pro offered for
//      the real check. The seller takes Zeno's number, either end of the
//      range or their own; then fixed or open to offers.
//   3. A cover: Zeno offers to make one from the photo, in the look most
//      sellers of this category pick (the Cover step's AI cover, counted
//      the same way). Keep it, or skip.
//   4. Done: everything goes into the wizard, which opens at the first
//      thing Zeno can't know (how many, where). The seller still sees, and
//      can change, every step before Go live - nothing is posted from here.
//
// Premium (PRICING.md section 4): the first look spends one of the plan's
// AI descriptions - one is free without a plan - and talking after it is
// free. A refusal offers the plans; writing the listing by hand stays free.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../services/photo_upload_tracker.dart';
import '../../../services/sell_wizard_data.dart';
import '../../../services/showcase_generator.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/broka_image.dart';
import '../../../widgets/chat_parts.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/zeno_avatar.dart';
import '../../premium/data/premium_repository.dart';
import '../../premium/domain/premium.dart';
import '../../premium/presentation/premium_upsell.dart';
import '../data/zeno_selling_repository.dart';
import '../domain/zeno_selling.dart';

/// Puts what Zeno filled in into the wizard's draft. Only what Zeno knows:
/// a category it couldn't file stays for the seller to choose, and a
/// question the seller skipped is left out of the description rather than
/// published as an empty "Label:" line.
void applyZenoListing(SellWizardData data, ZenoAutoListing listing) {
  if (listing.name.trim().length >= 3) {
    final name = listing.name.trim();
    data.name = name.length > SellWizardData.maxNameLength
        ? name.substring(0, SellWizardData.maxNameLength)
        : name;
  }
  if (listing.category != null && listing.categoryId != null) {
    final moved = data.categoryId != listing.categoryId || data.subcategoryId != listing.subcategoryId;
    data
      ..category = listing.category!
      ..categoryId = listing.categoryId
      ..subcategoryId = listing.subcategoryId
      ..subcategoryName = listing.subcategory;
    // Another kind of item: the previous one's details don't apply.
    if (moved) data.attributes = {};
  }
  if (listing.condition != null) data.condition = listing.condition;
  data.attributes.addAll(listing.attributes);
  final description = listing.description.trim();
  if (description.isNotEmpty) {
    data.description = description.length > SellWizardData.maxDescriptionLength
        ? description.substring(0, SellWizardData.maxDescriptionLength)
        : description;
  }
}

enum _Stage { looking, talking, pricing, priced, negotiable, covering, done, stuck }

class _Entry {
  _Entry.zeno(this.text, {this.questions = const []})
      : fromZeno = true,
        photo = null;
  _Entry.seller(this.text)
      : fromZeno = false,
        questions = const [],
        photo = null;
  _Entry.photo(File this.photo)
      : fromZeno = false,
        text = '',
        questions = const [];

  final String text;
  final bool fromZeno;
  final List<ZenoDescribeQuestion> questions;
  final File? photo;
}

class ZenoAutolistScreen extends StatefulWidget {
  const ZenoAutolistScreen({
    super.key,
    required this.data,
    this.repository,
    this.generator,
    this.premium,
    this.animateBackground = true,
  });

  /// The listing being written: its photos, and where the result goes.
  final SellWizardData data;

  /// For tests.
  final ZenoSellingRepository? repository;
  final ShowcaseGenerator? generator;
  final PremiumRepository? premium;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  /// Opens the screen. Resolves true when the seller finished with Zeno
  /// (the draft holds the listing - open the wizard at what is left),
  /// false when they left early (whatever Zeno had filled in is in the
  /// draft too, for the steps to show).
  static Future<bool> open(BuildContext context, SellWizardData data) async =>
      await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => ZenoAutolistScreen(data: data))) ??
      false;

  @override
  State<ZenoAutolistScreen> createState() => _ZenoAutolistScreenState();
}

class _ZenoAutolistScreenState extends State<ZenoAutolistScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_Entry> _entries = [];
  final List<Map<String, String>> _history = [];

  _Stage _stage = _Stage.looking;
  bool _thinking = false;
  ZenoAutoTurn? _turn;
  ZenoPriceRange? _range;
  int? _price;
  GeneratedCover? _cover;
  bool _coverKept = false;
  PremiumStatus? _premium;

  // What went wrong last, with a way to try it again.
  VoidCallback? _retry;

  SellWizardData get _data => widget.data;
  ZenoSellingRepository get _repo => widget.repository ?? zenoSellingRepository;
  ShowcaseGenerator get _generator => widget.generator ?? ShowcaseGenerator();
  File? get _photo => _data.verifiedPhotos.isEmpty ? null : _data.verifiedPhotos.first;
  String get _theme => ShowcaseGenerator.recommendedFor(_turn?.listing.category ?? _data.category);
  String get _themeName =>
      ShowcaseGenerator.themes.firstWhere((t) => t.id == _theme, orElse: () => ShowcaseGenerator.themes.first).name;

  @override
  void initState() {
    super.initState();
    final photo = _photo;
    if (photo != null) _entries.add(_Entry.photo(photo));
    _loadPremium();
    _look();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPremium() async {
    final r = await (widget.premium ?? premiumRepository).me();
    if (mounted && r is Success<PremiumStatus>) setState(() => _premium = r.data);
  }

  void _say(String text, {List<ZenoDescribeQuestion> questions = const []}) {
    _entries.add(_Entry.zeno(text, questions: questions));
    _history.add({
      'role': 'assistant',
      'content': [text, for (final (i, q) in questions.indexed) '${i + 1}. ${q.question}'].join('\n'),
    });
    _scrollDown();
  }

  void _stuck(String message, VoidCallback retry) {
    setState(() {
      _thinking = false;
      _stage = _Stage.stuck;
      _retry = retry;
      _entries.add(_Entry.zeno(message));
    });
    _scrollDown();
  }

  // ── 1. The look ──────────────────────────────────────────────────────────

  Future<void> _look() async {
    setState(() {
      _stage = _Stage.looking;
      _thinking = true;
      _retry = null;
    });
    final photo = _photo;
    if (photo == null) {
      _stuck('Take a photo of the item first - I list it from the photo.', _look);
      return;
    }
    try {
      final ids = await _data.photoUploads.idsFor([photo]);
      final turn = await _repo.autolist(
        photoId: ids.first,
        language: ApiService.currentUserLanguage,
        draft: _data.name.trim().isEmpty ? const {} : zenoListingDraft(_data),
      );
      if (!mounted) return;
      if (_premium?.enabled ?? false) _loadPremium();
      setState(() {
        _turn = turn;
        _thinking = false;
        _stage = _Stage.talking;
        _say(turn.reply.isEmpty ? _firstReply(turn) : turn.reply, questions: turn.questions);
      });
    } on PhotoUploadIncomplete {
      if (mounted) {
        _stuck("Your photo hasn't finished uploading. Check your connection, then try again.", _look);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _stuck(e.message, _look);
      if (isPlanRefusal(e.statusCode)) {
        final opened = await showPremiumUpsell(context,
            message: e.message, upgradeTo: upgradeToOf(e), feature: PremiumFeature.aiDescriptions, premium: widget.premium);
        if (opened && mounted) await _loadPremium();
      }
    } catch (_) {
      if (mounted) _stuck("I couldn't reach BROKA. Check your connection and try again.", _look);
    }
  }

  String _firstReply(ZenoAutoTurn turn) {
    final where = turn.listing.filedUnder;
    final start = where.isEmpty
        ? "Here's your listing from the photo."
        : "This looks like ${turn.listing.name} - I've filed it under $where.";
    return turn.questions.isEmpty ? '$start Check it over.' : '$start A few things buyers will ask:';
  }

  // ── The seller's answers ─────────────────────────────────────────────────

  Future<void> _send(String text) async {
    final message = text.trim();
    final current = _turn;
    if (message.isEmpty || _thinking || current == null) return;
    _msgCtrl.clear();
    final history = List.of(_history);
    setState(() {
      _entries.add(_Entry.seller(message));
      _thinking = true;
    });
    _history.add({'role': 'user', 'content': message});
    _scrollDown();
    try {
      final turn = await _repo.autolistTurn(
        listing: current.listing,
        questions: current.questions,
        message: message,
        history: history,
        language: ApiService.currentUserLanguage,
      );
      if (!mounted) return;
      setState(() {
        _turn = turn;
        _thinking = false;
        _say(turn.reply.isEmpty
            ? (turn.questions.isEmpty ? 'Got it - your listing is ready for a price.' : 'Got it. A few things are still open:')
            : turn.reply,
            questions: turn.questions);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _history.removeLast();
      setState(() {
        _thinking = false;
        _entries.add(_Entry.zeno(e.message));
      });
      if (isPlanRefusal(e.statusCode)) {
        await showPremiumUpsell(context,
            message: e.message, upgradeTo: upgradeToOf(e), feature: PremiumFeature.aiDescriptions, premium: widget.premium);
      }
    } catch (_) {
      if (!mounted) return;
      _history.removeLast();
      setState(() {
        _thinking = false;
        _entries.add(_Entry.zeno("⚠️ I couldn't reach BROKA. Check your connection and try again."));
      });
    } finally {
      _scrollDown();
    }
  }

  // ── 2. The price ─────────────────────────────────────────────────────────

  Future<void> _priceIt() async {
    final turn = _turn;
    if (turn == null || _thinking) return;
    // The listing as it stands goes into the draft now: the price is for
    // this item, and leaving from here keeps what Zeno wrote.
    applyZenoListing(_data, turn.listing);
    setState(() {
      _entries.add(_Entry.seller('Looks right - what should I ask?'));
      _stage = _Stage.pricing;
      _thinking = true;
      _retry = null;
    });
    _scrollDown();
    try {
      final range = await _repo.autolistPrice(
        draft: zenoListingDraft(_data),
        language: ApiService.currentUserLanguage,
      );
      if (!mounted) return;
      if (_premium?.enabled ?? false) _loadPremium();
      setState(() {
        _range = range;
        _thinking = false;
        _stage = _Stage.priced;
        _say(range.reply.isEmpty
            ? 'I\'d ask KES ${formatKesAmount(range.suggested)}.'
            : range.reply);
      });
    } on ApiException catch (e) {
      if (mounted) _stuck('${e.message} You can also set your own price.', _priceIt);
    } catch (_) {
      if (mounted) _stuck("I couldn't reach BROKA. Check your connection and try again.", _priceIt);
    }
  }

  void _takePrice(int price, {String? said}) {
    setState(() {
      _price = price;
      _data.price = '$price';
      _entries.add(_Entry.seller(said ?? "I'll ask KES ${formatKesAmount(price)}"));
      _stage = _Stage.negotiable;
      _say('Fixed price, or open to offers? If you take offers, I bring you each one to accept or counter.');
    });
  }

  Future<void> _ownPrice() async {
    final ctrl = TextEditingController(text: _price != null ? formatKesAmount(_price!) : '');
    String? problem;
    final price = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          backgroundColor: BrokaColors.bgCard,
          title: const Text('Your price', style: TextStyle(color: BrokaColors.textHigh)),
          content: TextField(
            key: const Key('zeno-autolist-own-price'),
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: const [KesInputFormatter()],
            style: const TextStyle(color: BrokaColors.gold, fontSize: 20, fontWeight: FontWeight.w800),
            decoration: InputDecoration(prefixText: 'KES  ', errorText: problem),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            TextButton(
              key: const Key('zeno-autolist-own-price-ok'),
              onPressed: () {
                final value = parseKesInput(ctrl.text);
                if (value == null || value <= 0 || value > maxListingPriceKes) {
                  setInner(() => problem = value != null && value > maxListingPriceKes
                      ? 'At most ${formatKes(maxListingPriceKes)}'
                      : 'Enter a price');
                  return;
                }
                Navigator.of(ctx).pop(value.round());
              },
              child: const Text('Use this price'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (price != null && mounted) _takePrice(price);
  }

  void _setNegotiable(bool negotiable) {
    setState(() {
      _data.priceNegotiable = negotiable;
      _entries.add(_Entry.seller(negotiable ? 'Open to offers' : 'Fixed price'));
    });
    _offerCover();
  }

  // ── 3. The cover ─────────────────────────────────────────────────────────

  bool get _coversOn => _premium?.enabled ?? false;
  bool get _coversLocked => !(_premium?.canUse(PremiumFeature.aiCovers) ?? true);

  void _offerCover() {
    // AI covers are off whenever plans are (PRICING.md): there is nothing
    // to offer, and the Cover step still takes one from the gallery.
    if (!_coversOn || _data.hasShowcase) {
      _finish();
      return;
    }
    setState(() {
      _stage = _Stage.covering;
      _say('Last thing: your cover is the first thing buyers see on Home. Want me to make one from '
          'your photo in $_themeName? Your item stays exactly as it is - only the setting changes.');
    });
  }

  Future<void> _makeCover() async {
    if (_thinking) return;
    if (_coversLocked) {
      final p = _premium;
      final opened = await showPremiumUpsell(context,
          message: p != null && p.hasPlan
              ? "You've used this month's AI cover tries on BROKA ${p.planName}."
              : "You've used your free AI cover try.",
          upgradeTo: p != null && p.hasPlan ? null : 'plus',
          feature: PremiumFeature.aiCovers, premium: widget.premium);
      if (opened && mounted) await _loadPremium();
      return;
    }
    setState(() {
      _thinking = true;
      _cover = null;
    });
    _scrollDown();
    try {
      final ids = await _data.photoUploads.idsFor([_photo!]);
      final cover = await _generator.generate(
        photoId: ids.first,
        name: _data.name,
        category: _data.category,
        theme: _theme,
        condition: _data.condition,
      );
      if (!mounted) return;
      if (_premium?.enabled ?? false) _loadPremium();
      setState(() {
        _thinking = false;
        _cover = cover;
        _say('Here it is. Keep it?');
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _entries.add(_Entry.zeno(e.message));
      });
      if (isPlanRefusal(e.statusCode)) {
        final opened = await showPremiumUpsell(context,
            message: e.message, upgradeTo: upgradeToOf(e), feature: PremiumFeature.aiCovers, premium: widget.premium);
        if (opened && mounted) await _loadPremium();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _entries.add(_Entry.zeno("I couldn't make the cover just now. You can try again in the Cover step."));
      });
    } finally {
      _scrollDown();
    }
  }

  void _keepCover(bool keep) {
    final cover = _cover;
    setState(() {
      if (keep && cover != null) {
        _data.setAiShowcase(assetId: cover.assetId, previewUrl: cover.previewUrl, theme: _theme);
        _coverKept = true;
      }
      _entries.add(_Entry.seller(keep && cover != null ? 'Keep it' : 'Skip the cover'));
    });
    _finish();
  }

  // ── 4. Done ──────────────────────────────────────────────────────────────

  void _finish() {
    final turn = _turn;
    if (turn != null) applyZenoListing(_data, turn.listing);
    _data.persist();
    setState(() {
      _stage = _Stage.done;
      _say("Done - I've filled in your listing. Just tell buyers how many you have and where it is, "
          'then check everything before it goes live.');
    });
  }

  /// Leaving before the end keeps what Zeno has filled in: the photo was
  /// counted, and the answers are the seller's.
  void _leave({required bool finished}) {
    final turn = _turn;
    if (turn != null) applyZenoListing(_data, turn.listing);
    _data.persist();
    Navigator.of(context).pop(finished);
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    });
  }

  // ── Building ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(finished: false);
      },
      child: Scaffold(
        backgroundColor: BrokaColors.bg,
        body: ConstellationBackground(
          animate: widget.animateBackground,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.2,
                colors: [BrokaColors.neonPurple.withOpacity(0.14), Colors.transparent],
                stops: const [0.0, 0.6],
              ),
            ),
            child: SafeArea(
              child: Column(children: [
                _header(),
                _progress(),
                Expanded(
                  child: ListView(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                    children: [
                      for (final e in _entries) _entry(e),
                      if (_turn != null && _stage == _Stage.talking) _listingCard(_turn!),
                      if (_thinking) _thinkingBubble(),
                      if (!_thinking) _actions(),
                    ],
                  ),
                ),
                if (_stage == _Stage.talking) _composer(),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 14, 10),
        child: Row(children: [
          IconButton(
            key: const Key('zeno-autolist-back'),
            tooltip: 'Back',
            onPressed: () => _leave(finished: false),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: BrokaColors.textHigh, size: 19),
          ),
          const ZenoAvatar(size: 38, glow: true),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              ZoneGlowText('Zeno', gradient: kChatGradient, fontSize: 20, maxLines: 1, letterSpacing: 1.6),
              SizedBox(height: 3),
              Text('Listing it for you',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
            ]),
          ),
        ]),
      );

  /// Details, price, cover, done - where the seller is in it.
  Widget _progress() {
    final at = switch (_stage) {
      _Stage.looking || _Stage.talking => 0,
      _Stage.pricing || _Stage.priced || _Stage.negotiable => 1,
      _Stage.covering => 2,
      _Stage.done => 3,
      _Stage.stuck => _range != null ? 1 : 0,
    };
    const labels = ['Details', 'Price', 'Cover', 'Done'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++) ...[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: i <= at ? const LinearGradient(colors: kChatGradient) : null,
                  color: i <= at ? null : BrokaColors.border,
                ),
              ),
              const SizedBox(height: 6),
              Text(labels[i],
                  style: TextStyle(
                      color: i <= at ? BrokaColors.textHigh : BrokaColors.textMid,
                      fontSize: 11,
                      fontWeight: i == at ? FontWeight.w800 : FontWeight.w600)),
            ]),
          ),
          if (i < labels.length - 1) const SizedBox(width: 8),
        ],
      ]),
    );
  }

  Widget _entry(_Entry e) {
    if (e.photo != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Align(
          alignment: Alignment.centerRight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(e.photo!, width: 150, height: 150, fit: BoxFit.cover, cacheWidth: 400,
                errorBuilder: (_, __, ___) => Container(width: 150, height: 150, color: BrokaColors.bgCard)),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: e.fromZeno ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (e.fromZeno) ...[const ZenoAvatar(size: 28), const SizedBox(width: 10)],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
              decoration: BoxDecoration(
                color: e.fromZeno ? BrokaColors.bgCard.withOpacity(0.92) : null,
                gradient: e.fromZeno ? null : const LinearGradient(colors: kChatGradient),
                borderRadius: BorderRadius.circular(16),
                border: e.fromZeno ? Border.all(color: BrokaColors.neonPurple.withOpacity(0.30)) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.text,
                    style: TextStyle(
                        color: e.fromZeno ? BrokaColors.textHigh : Colors.white, fontSize: 14.5, height: 1.5)),
                for (final (i, q) in e.questions.indexed)
                  Padding(
                    key: Key('zeno-autolist-question-${q.label}'),
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${i + 1}. ${q.question}',
                        style: const TextStyle(
                            color: BrokaColors.textHigh, fontSize: 14, height: 1.45, fontWeight: FontWeight.w600)),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thinkingBubble() {
    final caption = switch (_stage) {
      _Stage.looking => 'Zeno is looking at your photo…',
      _Stage.pricing => 'Zeno is checking prices…',
      _Stage.covering => 'Zeno is making your $_themeName cover - this can take up to a minute…',
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const ZenoTypingBubble(),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(left: 38, top: 6),
            child: Text(caption, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          ),
      ]),
    );
  }

  /// The listing as buyers will see it, under Zeno's latest turn.
  Widget _listingCard(ZenoAutoTurn turn) {
    final l = turn.listing;
    final lines = l.description.split('\n').where((s) => s.trim().isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.only(left: 38, bottom: 16),
      child: Container(
        key: const Key('zeno-autolist-listing'),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.94),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.45)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('YOUR LISTING',
              style: TextStyle(color: BrokaColors.neonCyan, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
          const SizedBox(height: 10),
          Text(l.name,
              key: const Key('zeno-autolist-name'),
              style: const TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w800, height: 1.3)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _tag(l.filedUnder.isEmpty ? 'Category: you choose' : l.filedUnder, Icons.folder_open_rounded),
            if (l.condition != null) _tag(_conditionLabel(l.condition!), Icons.auto_awesome_rounded),
          ]),
          const SizedBox(height: 12),
          for (final line in lines) _line(line),
          if (turn.questions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              turn.questions.length == 1
                  ? "Answer below - or price it now and leave that out."
                  : 'Answer below - or price it now and leave those out.',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
            ),
          ],
        ]),
      ),
    );
  }

  static String _conditionLabel(String c) => switch (c) {
        'new' => 'New',
        'used' => 'Used',
        'refurbished' => 'Refurbished',
        _ => c,
      };

  Widget _tag(String text, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: BrokaColors.neonPurple.withOpacity(0.16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: BrokaColors.textHigh),
          const SizedBox(width: 5),
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 11.5, fontWeight: FontWeight.w700)),
          ),
        ]),
      );

  /// "RAM: 4 GB" with the label set apart.
  Widget _line(String line) {
    final at = line.indexOf(': ');
    const value = TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, height: 1.5);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: at <= 0
          ? Text(line, style: value)
          : Text.rich(TextSpan(children: [
              TextSpan(
                  text: line.substring(0, at + 1),
                  style: const TextStyle(color: BrokaColors.textMid, fontWeight: FontWeight.w700)),
              TextSpan(text: line.substring(at + 1)),
            ]), style: value),
    );
  }

  /// What the seller can do now, under the conversation.
  Widget _actions() {
    switch (_stage) {
      case _Stage.looking:
      case _Stage.pricing:
        return const SizedBox.shrink();
      case _Stage.talking:
        return _buttons([
          _primary('zeno-autolist-price', 'Looks right - price it', Icons.sell_rounded, _priceIt),
        ]);
      case _Stage.priced:
        return _priceOptions(_range!);
      case _Stage.negotiable:
        return _buttons([
          _choice('zeno-autolist-offers', '🤝  Open to offers', () => _setNegotiable(true)),
          _choice('zeno-autolist-fixed', '🔒  Fixed price', () => _setNegotiable(false)),
        ]);
      case _Stage.covering:
        if (_cover != null && !_coverKept) return _coverResult(_cover!);
        return _buttons([
          _primary('zeno-autolist-cover', _coversLocked ? '🔒  Make my cover' : '✨  Make my cover',
              Icons.auto_fix_high_rounded, _makeCover),
          _choice('zeno-autolist-skip-cover', 'Skip - use my photo', () => _keepCover(false)),
        ], footnote: _coverFootnote());
      case _Stage.done:
        return _doneCard();
      case _Stage.stuck:
        return _buttons([
          if (_retry != null) _primary('zeno-autolist-retry', 'Try again', Icons.refresh_rounded, _retry!),
          if (_range == null && _turn != null)
            _choice('zeno-autolist-own', 'Set my own price', _ownPrice),
          _choice('zeno-autolist-myself', _turn == null ? 'List it myself' : 'Finish it myself',
              () => _leave(finished: _turn != null)),
        ]);
    }
  }

  String? _coverFootnote() {
    final p = _premium;
    if (p == null || !p.enabled) return null;
    final left = p.left(PremiumFeature.aiCovers);
    if (p.hasPlan) return '$left AI cover ${left == 1 ? 'try' : 'tries'} left this month';
    if (left > 0) return left == 1 ? '1 free AI cover try left' : '$left free AI cover tries left';
    return 'AI covers come with BROKA Plus';
  }

  Widget _priceOptions(ZenoPriceRange range) {
    final p = _premium;
    final offerPro = !range.fromBroka && !range.canCheckBroka && (p?.enabled ?? false);
    return Padding(
      padding: const EdgeInsets.only(left: 38),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _RangeCard(range: range),
        const SizedBox(height: 14),
        _primary('zeno-autolist-take-price', 'Ask KES ${formatKesAmount(range.suggested)}',
            Icons.check_rounded, () => _takePrice(range.suggested)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (range.high != range.suggested)
            _chip('KES ${formatKesAmount(range.high)}', () => _takePrice(range.high)),
          if (range.low != range.suggested)
            _chip('KES ${formatKesAmount(range.low)}', () => _takePrice(range.low)),
          _chip('My own price', _ownPrice, key: const Key('zeno-autolist-own')),
        ]),
        if (offerPro) ...[
          const SizedBox(height: 14),
          InkWell(
            key: const Key('zeno-autolist-check-broka'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => showPremiumUpsell(context,
                message: 'This is my estimate. With BROKA Pro I check it against similar items live on '
                    'BROKA right now - what they ask, and where yours should sit.',
                upgradeTo: 'pro',
                feature: PremiumFeature.priceChecks, premium: widget.premium),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
                color: BrokaColors.gold.withOpacity(0.08),
              ),
              child: const Row(children: [
                Icon(Icons.lock_rounded, size: 16, color: BrokaColors.gold),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Check it against live BROKA listings',
                      style: TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
                Text('PRO', style: TextStyle(color: BrokaColors.gold, fontSize: 11, fontWeight: FontWeight.w900)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _coverResult(GeneratedCover cover) => Padding(
        padding: const EdgeInsets.only(left: 38),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(aspectRatio: 4 / 3, child: BrokaImage(cover.previewUrl, fit: BoxFit.cover)),
          ),
          const SizedBox(height: 14),
          _primary('zeno-autolist-keep-cover', 'Keep this cover', Icons.check_rounded, () => _keepCover(true)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _chip('Try again', _makeCover),
            _chip('Skip the cover', () => _keepCover(false)),
          ]),
        ]),
      );

  Widget _doneCard() {
    final done = <String>[
      'Title',
      if (_data.categoryId != null) 'Category',
      'Description',
      if (_price != null) 'Price',
      if (_coverKept) 'Cover',
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 38),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          key: const Key('zeno-autolist-done'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.94),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrokaColors.success.withOpacity(0.5)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('ZENO FILLED IN',
                style: TextStyle(color: BrokaColors.success, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in done)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_rounded, size: 16, color: BrokaColors.success),
                  const SizedBox(width: 5),
                  Text(d, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
                ]),
            ]),
            const SizedBox(height: 12),
            const Text('Left for you: how many you have, delivery and where it is.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          ]),
        ),
        const SizedBox(height: 14),
        _primary('zeno-autolist-finish', 'Finish my listing', Icons.arrow_forward_rounded,
            () => _leave(finished: true)),
      ]),
    );
  }

  Widget _buttons(List<Widget> children, {String? footnote}) => Padding(
        padding: const EdgeInsets.only(left: 38, bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, c) in children.indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            c,
          ],
          if (footnote != null) ...[
            const SizedBox(height: 8),
            Text(footnote,
                key: const Key('zeno-autolist-footnote'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, fontWeight: FontWeight.w600)),
          ],
        ]),
      );

  Widget _primary(String key, String label, IconData icon, VoidCallback onTap) => ElevatedButton.icon(
        key: Key(key),
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: BrokaColors.gold,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
        ),
      );

  Widget _choice(String key, String label, VoidCallback onTap) => OutlinedButton(
        key: Key(key),
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: BrokaColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(label,
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 14)),
      );

  Widget _chip(String label, VoidCallback onTap, {Key? key}) => ActionChip(
        key: key,
        label: Text(label),
        onPressed: onTap,
        backgroundColor: BrokaColors.bgCard,
        side: const BorderSide(color: BrokaColors.border),
        labelStyle: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w700),
      );

  Widget _composer() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 50),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.92),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45), width: 1.2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('zeno-autolist-input'),
                controller: _msgCtrl,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5),
                decoration: InputDecoration(
                  hintText: (_turn?.questions.isEmpty ?? true)
                      ? 'Correct anything, or add a detail…'
                      : 'Answer Zeno…',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
                onSubmitted: (v) => _send(v),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const Key('zeno-autolist-send'),
            tooltip: 'Send',
            onPressed: _thinking ? null : () => _send(_msgCtrl.text),
            style: IconButton.styleFrom(backgroundColor: BrokaColors.gold, minimumSize: const Size(50, 50)),
            icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
          ),
        ]),
      );
}

/// The fair range as a bar, with Zeno's number marked on it, and what it
/// stands on: BROKA's own listings, or Zeno's estimate.
class _RangeCard extends StatelessWidget {
  const _RangeCard({required this.range});
  final ZenoPriceRange range;

  @override
  Widget build(BuildContext context) {
    final span = range.high - range.low;
    final at = span <= 0 ? 0.5 : ((range.suggested - range.low) / span).clamp(0.0, 1.0);
    final basis = range.fromBroka
        ? 'Based on ${range.comparables?.count ?? 0} similar live listing${(range.comparables?.count ?? 0) == 1 ? '' : 's'} on BROKA'
        : "Zeno's estimate for Kenya";
    return Container(
      key: const Key('zeno-autolist-range'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(range.fromBroka ? Icons.verified_rounded : Icons.insights_rounded,
              size: 15, color: BrokaColors.neonGreen),
          const SizedBox(width: 6),
          Expanded(
            child: Text(basis.toUpperCase(),
                style: const TextStyle(
                    color: BrokaColors.neonGreen, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.7)),
          ),
        ]),
        const SizedBox(height: 12),
        Text('KES ${formatKesAmount(range.suggested)}',
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        const Text("Zeno's asking price", style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (_, box) {
          return SizedBox(
            height: 18,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(
                left: 0,
                right: 0,
                top: 6,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: LinearGradient(colors: [
                      BrokaColors.neonBlue.withOpacity(0.7),
                      BrokaColors.neonGreen,
                      BrokaColors.gold,
                    ]),
                  ),
                ),
              ),
              Positioned(
                left: (box.maxWidth - 18) * at,
                top: 0,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: BrokaColors.neonGreen, width: 3),
                  ),
                ),
              ),
            ]),
          );
        }),
        const SizedBox(height: 8),
        Row(children: [
          Text('KES ${formatKesAmount(range.low)}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('KES ${formatKesAmount(range.high)}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }
}
