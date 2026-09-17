// BROKA - User Search Screen
// Search for users by name, nickname or email.
// Tapping a result opens their public UserProfileScreen.
// Location is only shown if the user has opted in (location_visible = true).

import 'dart:convert';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool   _loading  = false;
  bool   _searched = false;
  String _query    = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final trimmed = q.trim();
    if (trimmed.isEmpty) {
      setState(() { _results = []; _searched = false; });
      return;
    }
    setState(() { _loading = true; _searched = true; _query = trimmed; });
    try {
      final raw = await ApiService.searchUsers(trimmed);
      if (mounted) {
        setState(() {
          _results = List<Map<String, dynamic>>.from(raw);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bgMid,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textMid, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Find Traders',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 16, fontWeight: FontWeight.w800)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BrokaColors.border),
              ),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
                textInputAction: TextInputAction.search,
                onSubmitted: _search,
                onChanged: (v) {
                  if (v.isEmpty) setState(() { _results = []; _searched = false; });
                },
                decoration: InputDecoration(
                  hintText: 'Search by name, nickname or email...',
                  hintStyle: const TextStyle(
                      color: BrokaColors.textLow, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded,
                      color: BrokaColors.textLow, size: 20),
                  suffixIcon: _ctrl.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _ctrl.clear();
                            setState(() { _results = []; _searched = false; });
                          },
                          child: const Icon(Icons.close_rounded,
                              color: BrokaColors.textLow, size: 18))
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                ),
              ),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(
          color: BrokaColors.gold));
    }
    if (!_searched) {
      return _buildEmptyHint();
    }
    if (_results.isEmpty) {
      return _buildNoResults();
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _UserCard(
        user: _results[i],
        onTap: () => Navigator.pushNamed(
            context, '/user-profile',
            arguments: _results[i]['id']),
      ),
    );
  }

  Widget _buildEmptyHint() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 72, height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: BrokaColors.gold.withOpacity(0.08),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.2)),
        ),
        child: const Icon(Icons.person_search_rounded,
            color: BrokaColors.gold, size: 36),
      ),
      const SizedBox(height: 16),
      const Text('Search for traders',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const Text('Find buyers and sellers by name or email',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
    ]),
  );

  Widget _buildNoResults() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.search_off_rounded,
          color: BrokaColors.textLow, size: 52),
      const SizedBox(height: 12),
      const Text('No traders found',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text('No results for "$_query"',
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
    ]),
  );
}

// ── User Result Card ──────────────────────────────────────────────────────────

class _UserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final VoidCallback onTap;
  const _UserCard({required this.user, required this.onTap});

  String get _displayName {
    final nick = user['nickname'] as String?;
    return (nick != null && nick.isNotEmpty)
        ? nick
        : user['name'] as String? ?? 'Broka User';
  }

  String get _initials {
    final name = user['name'] as String? ?? 'B';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : 'B';
  }

  @override
  Widget build(BuildContext context) {
    final photo    = user['profile_photo'] as String?;
    final verified = user['is_verified'] as bool? ?? false;
    final rating   = (user['rating'] as num?)?.toStringAsFixed(1) ?? '5.0';
    final deals    = user['completed_deals'] as int? ?? 0;
    final location = user['location_name'] as String?; // null if hidden
    final dist     = user['distance_km'];
    final since    = user['member_since'] as String?;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: BrokaColors.cardGradColors,
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          // Avatar
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.goldDim]),
              border: Border.all(
                  color: BrokaColors.gold.withOpacity(0.4)),
            ),
            child: ClipOval(child: photo != null && photo.isNotEmpty
                ? Image.memory(base64Decode(photo), fit: BoxFit.cover)
                : Center(child: Text(_initials, style: const TextStyle(
                    color: Colors.white, fontSize: 18,
                    fontWeight: FontWeight.w800)))),
          ),
          const SizedBox(width: 14),
          // Info
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(_displayName, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 15,
                    fontWeight: FontWeight.w700)),
                if (verified) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: BrokaColors.neonGreen.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: BrokaColors.neonGreen.withOpacity(0.4)),
                    ),
                    child: const Text('✓', style: TextStyle(
                        color: BrokaColors.neonGreen,
                        fontSize: 10, fontWeight: FontWeight.w800)),
                  ),
                ],
              ]),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.star_rounded,
                    color: BrokaColors.gold, size: 13),
                const SizedBox(width: 3),
                Text(rating, style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12)),
                const SizedBox(width: 10),
                const Icon(Icons.handshake_outlined,
                    color: BrokaColors.textLow, size: 12),
                const SizedBox(width: 3),
                Text('$deals deals', style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12)),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                if (location != null) ...[
                  const Icon(Icons.location_on_rounded,
                      color: BrokaColors.neonBlue, size: 12),
                  const SizedBox(width: 3),
                  Text(
                    dist != null ? '$location · ${dist}km' : location,
                    style: const TextStyle(
                        color: BrokaColors.textLow, fontSize: 11),
                  ),
                ] else ...[
                  const Icon(Icons.location_off_outlined,
                      color: BrokaColors.textLow, size: 12),
                  const SizedBox(width: 3),
                  const Text('Location private',
                      style: TextStyle(
                          color: BrokaColors.textLow, fontSize: 11)),
                ],
                if (since != null) ...[
                  const SizedBox(width: 10),
                  Text('Joined $since', style: const TextStyle(
                      color: BrokaColors.textLow, fontSize: 11)),
                ],
              ]),
            ],
          )),
          const Icon(Icons.arrow_forward_ios_rounded,
              color: BrokaColors.textLow, size: 14),
        ]),
      ),
    );
  }
}
