// The Seller Dashboard's "marked unavailable" list: the seller's listings a
// buyer said are no longer available (backend listings/sold_out.py).
//
// It has to exist because nothing else shows them. One buyer's report takes
// a listing out of every list buyers browse - and out of this dashboard's
// catalogue, which is read from the same lists - so a seller whose item was
// still for sale had no way to find it and say so, and a mistaken report
// kept it hidden for good. The text and the push the seller gets when it
// is reported both send them here.
//
// "Still available" puts it back on sale (DELETE /listings/{id}/sold-out);
// "It's sold" removes it, the same soft delete as the catalogue's Delete.
// Draws nothing when there is nothing reported, or when the list can't be
// loaded: it is a prompt, not a section the dashboard depends on.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/broka_image.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../data/reported_listings_repository.dart';

class ReportedUnavailablePanel extends StatefulWidget {
  const ReportedUnavailablePanel({
    super.key,
    this.reloadSignal = 0,
    this.onChanged,
    this.repository,
    this.listings,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 4),
  });

  /// Changes whenever the dashboard refreshes; the panel reloads with it.
  final int reloadSignal;

  /// A listing went back on sale or was removed: the catalogue changed.
  final VoidCallback? onChanged;

  final EdgeInsets margin;

  /// For tests.
  final ReportedListingsRepository? repository;
  final ListingsRepository? listings;

  @override
  State<ReportedUnavailablePanel> createState() => _ReportedUnavailablePanelState();
}

class _ReportedUnavailablePanelState extends State<ReportedUnavailablePanel> {
  List<ReportedListing> _reported = const [];
  final Set<String> _busy = {};

  ReportedListingsRepository get _repo => widget.repository ?? reportedListingsRepository;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReportedUnavailablePanel old) {
    super.didUpdateWidget(old);
    if (old.reloadSignal != widget.reloadSignal) _load();
  }

  Future<void> _load() async {
    final r = await _repo.mine();
    if (!mounted) return;
    if (r case Success(:final data)) setState(() => _reported = data);
  }

  void _drop(String id) =>
      setState(() => _reported = [for (final r in _reported) if (r.listing.id != id) r]);

  Future<void> _stillAvailable(ReportedListing item) async {
    final l = item.listing;
    HapticFeedback.selectionClick();
    setState(() => _busy.add(l.id));
    final r = await _repo.stillAvailable(l.id);
    if (!mounted) return;
    setState(() => _busy.remove(l.id));
    final messenger = ScaffoldMessenger.of(context);
    switch (r) {
      case Success():
        _drop(l.id);
        widget.onChanged?.call();
        messenger.showSnackBar(SnackBar(
          content: Text('"${l.name}" is back on sale - buyers can see it again.'),
          behavior: SnackBarBehavior.floating,
        ));
      case Failure(:final message):
        messenger.showSnackBar(SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: BrokaColors.danger,
        ));
    }
  }

  /// It really has gone: asks first, then takes it off BROKA.
  Future<void> _sold(ReportedListing item) async {
    final l = item.listing;
    HapticFeedback.selectionClick();
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrokaColors.border)),
        title: const Text('It\'s sold?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 17)),
        content: Text(
            '"${l.name}" will be removed from BROKA for good. This can\'t be undone.',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it', style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            key: const Key('confirm-remove-reported'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: BrokaColors.danger, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy.add(l.id));
    final r = await (widget.listings ?? listingsRepository).deleteListing(l.id);
    if (!mounted) return;
    setState(() => _busy.remove(l.id));
    final messenger = ScaffoldMessenger.of(context);
    switch (r) {
      case Success():
        _drop(l.id);
        widget.onChanged?.call();
        messenger.showSnackBar(SnackBar(
          content: Text('"${l.name}" removed'),
          behavior: SnackBarBehavior.floating,
        ));
      case Failure(:final message):
        messenger.showSnackBar(SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: BrokaColors.danger,
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_reported.isEmpty) return const SizedBox.shrink();
    final n = _reported.length;
    return Container(
      key: const Key('reported-unavailable-panel'),
      margin: widget.margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.danger.withOpacity(0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.report_problem_rounded, color: BrokaColors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              n == 1 ? 'A buyer marked a listing unavailable' : 'Buyers marked $n listings unavailable',
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        const Text('Buyers can\'t see these until you say they\'re still for sale. '
            'Not true? Tap Still available. Sold? Remove it.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.35)),
        const SizedBox(height: 6),
        for (final item in _reported)
          _Row(
            item: item,
            busy: _busy.contains(item.listing.id),
            onStillAvailable: () => _stillAvailable(item),
            onSold: () => _sold(item),
          ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.busy,
    required this.onStillAvailable,
    required this.onSold,
  });

  final ReportedListing item;
  final bool busy;
  final VoidCallback onStillAvailable;
  final VoidCallback onSold;

  String get _when {
    final at = item.reportedAt;
    if (at == null) return 'Hidden from buyers';
    final ago = DateTime.now().difference(at);
    final label = ago.inMinutes < 1
        ? 'just now'
        : ago.inHours < 1
            ? '${ago.inMinutes}m ago'
            : ago.inDays < 1
                ? '${ago.inHours}h ago'
                : '${ago.inDays}d ago';
    return 'Hidden since $label';
  }

  String? get _thumb {
    final l = item.listing;
    return l.cover?.thumb ?? (l.photos.isNotEmpty ? l.photos.first.thumb : null);
  }

  @override
  Widget build(BuildContext context) {
    final l = item.listing;
    final reports = item.openReports > 1 ? ' · ${item.openReports} buyers' : '';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: BrokaImage(_thumb, width: 44, height: 44,
                placeholder: Container(
                  width: 44, height: 44, color: BrokaColors.bgMid,
                  alignment: Alignment.center,
                  child: Text(l.emoji, style: const TextStyle(fontSize: 20)),
                )),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
              Text('${formatKes(l.price)} · $_when$reports',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: Key('reported-still-available-${l.id}'),
              onPressed: busy ? null : onStillAvailable,
              style: FilledButton.styleFrom(
                backgroundColor: BrokaColors.neonGreen.withOpacity(0.18),
                foregroundColor: BrokaColors.neonGreen,
                minimumSize: const Size.fromHeight(38),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: busy
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.neonGreen))
                  : const Icon(Icons.check_circle_outline_rounded, size: 18),
              label: const Text('Still available', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: Key('reported-sold-${l.id}'),
            onPressed: busy ? null : onSold,
            style: TextButton.styleFrom(
              foregroundColor: BrokaColors.textMid,
              minimumSize: const Size(0, 38),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('It\'s sold', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ]),
      ]),
    );
  }
}
