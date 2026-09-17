// BROKA - Buyer Safety & Tips Screen
// Convinces buyers to use BROKA escrow, explains protections,
// and indirectly drives on-platform transactions.

import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';

class BuyerTipsScreen extends StatefulWidget {
  const BuyerTipsScreen({super.key});
  @override
  State<BuyerTipsScreen> createState() => _BuyerTipsScreenState();
}

class _BuyerTipsScreenState extends State<BuyerTipsScreen>
    with SingleTickerProviderStateMixin {

  late AnimationController _animCtrl;
  late Animation<double>   _fadeAnim;
  int _expandedTip = 0;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  static const _escrowSteps = [
    _EscrowStep(
      icon: Icons.account_balance_wallet_rounded,
      color: Color(0xFF7C5CFC),
      title: 'Buyer Pays into Escrow',
      body: 'Your M-Pesa payment goes into BROKA\'s secure escrow account — '
            'not directly to the seller. The seller cannot touch it yet.',
    ),
    _EscrowStep(
      icon: Icons.local_shipping_rounded,
      color: Color(0xFF4FC3F7),
      title: 'Seller Delivers the Item',
      body: 'With the funds secured, the seller is motivated to deliver exactly '
            'what was agreed. Both sides know there\'s no turning back.',
    ),
    _EscrowStep(
      icon: Icons.verified_rounded,
      color: Color(0xFF00D68F),
      title: 'You Confirm Receipt',
      body: 'Once you receive and inspect the item, you tap "Confirm" in the app. '
            'Only then does BROKA release the funds to the seller.',
    ),
    _EscrowStep(
      icon: Icons.auto_awesome_rounded,
      color: Color(0xFFFFB347),
      title: 'Zeno Resolves Any Disputes',
      body: 'If something\'s wrong, Zeno reviews the chat history, images, and '
            'agreed terms — and issues a fair verdict within 24 hours.',
    ),
  ];

  static const _safetyTips = [
    _SafetyTip(
      icon: Icons.chat_rounded,
      color: Color(0xFF7C5CFC),
      title: 'Keep all communication on BROKA',
      shortDesc: 'Never move to WhatsApp or call outside the app',
      fullDesc: 'Sellers may ask to move to WhatsApp or give you a phone number. '
                'Resist this. Every message you send inside BROKA is '
                'timestamped and stored — it becomes evidence if a dispute '
                'arises. Conversations outside the platform are invisible to '
                'Zeno and cannot be used in dispute resolution.',
      risk: 'HIGH RISK if ignored',
    ),
    _SafetyTip(
      icon: Icons.lock_rounded,
      color: Color(0xFF00D68F),
      title: 'Always use BROKA Escrow',
      shortDesc: 'Never pay directly via M-Pesa to the seller',
      fullDesc: 'Paying directly gives you zero protection. Once M-Pesa funds '
                'leave your wallet to the seller, there is no guaranteed '
                'refund path. BROKA Escrow holds your money until you '
                'confirm you\'re happy — that\'s the only way to stay protected.',
      risk: 'HIGH RISK if ignored',
    ),
    _SafetyTip(
      icon: Icons.photo_camera_rounded,
      color: Color(0xFF4FC3F7),
      title: 'Request verification photos',
      shortDesc: 'Ask the seller to send live photos before agreeing',
      fullDesc: 'Before finalising any deal, ask the seller to send fresh photos '
                'of the exact item — not stock photos. This '
                'proves the item exists as described and gives Zeno visual '
                'evidence if you later raise a dispute.',
      risk: 'MEDIUM RISK if ignored',
    ),
    _SafetyTip(
      icon: Icons.place_rounded,
      color: Color(0xFFFFB347),
      title: 'Meet in a safe public place',
      shortDesc: 'Use busy markets, matatu stages, or banks',
      fullDesc: 'For physical handovers, always meet in a visible public space — '
                'a busy market, a bank entrance, or a matatu stage. Never go '
                'to a seller\'s private residence alone. Bring a friend when '
                'possible, especially for high-value items.',
      risk: 'MEDIUM RISK if ignored',
    ),
    _SafetyTip(
      icon: Icons.verified_user_rounded,
      color: Color(0xFFFF6EAD),
      title: 'Check the seller\'s trust scores',
      shortDesc: 'Reliability, Trust, and Rating must all be above 7/10',
      fullDesc: 'Before negotiating, tap the seller\'s profile. Check three things: '
                'Reliability Score (do they complete deals?), Trust Score '
                '(do buyers vouch for them?), and Pending Deals (too many '
                'pending suggests they often fail to close). A verified badge '
                'means BROKA has confirmed their identity.',
      risk: 'MEDIUM RISK if ignored',
    ),
    _SafetyTip(
      icon: Icons.warning_amber_rounded,
      color: Color(0xFFFF6B6B),
      title: 'Trust Zeno\'s price warnings',
      shortDesc: 'Prices far below market are a red flag',
      fullDesc: 'When Zeno flags that a price is "significantly below market value", '
                'take it seriously. Common scam: list a phone at KES 5,000 '
                '(worth 45,000), collect the "deposit" via M-Pesa, then '
                'disappear. If the deal looks too good to be true, it usually is.',
      risk: 'HIGH RISK if ignored',
    ),
  ];

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final name = ApiService.currentUserName?.split(' ').first ?? 'Buyer';
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: FadeTransition(
        opacity: _fadeAnim,
        child: CustomScrollView(
          slivers: [
            _buildAppBar(name),
            SliverToBoxAdapter(child: _buildEscrowBanner()),
            SliverToBoxAdapter(child: _buildEscrowFlow()),
            SliverToBoxAdapter(child: _buildSectionLabel('SAFETY TIPS')),
            SliverList(delegate: SliverChildBuilderDelegate(
              (ctx, i) => _buildTipCard(i),
              childCount: _safetyTips.length,
            )),
            SliverToBoxAdapter(child: _buildBottomCta()),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  // ── App bar ───────────────────────────────────────────────────────────────

  Widget _buildAppBar(String name) => SliverAppBar(
    backgroundColor: BrokaColors.bgMid,
    pinned: true,
    expandedHeight: 120,
    leading: GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Icon(Icons.arrow_back_ios_new_rounded,
            color: BrokaColors.textMid, size: 16),
      ),
    ),
    flexibleSpace: FlexibleSpaceBar(
      collapseMode: CollapseMode.pin,
      background: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0D1B2A), Color(0xFF0A0F1E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 48, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: BrokaColors.neonGreen.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: BrokaColors.neonGreen.withOpacity(0.35)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shield_rounded,
                            color: BrokaColors.neonGreen, size: 11),
                        SizedBox(width: 4),
                        Text('BUYER PROTECTION',
                            style: TextStyle(
                                color: BrokaColors.neonGreen,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8)),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                  '$name, here\'s how to stay safe',
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  // ── Escrow banner ─────────────────────────────────────────────────────────

  Widget _buildEscrowBanner() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            BrokaColors.gold.withOpacity(0.18),
            BrokaColors.neonBlue.withOpacity(0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: BrokaColors.gold.withOpacity(0.4), width: 1.5),
      ),
      child: Row(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [BrokaColors.gold, BrokaColors.neonBlue]),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.security_rounded,
              color: Colors.white, size: 24),
        ),
        const SizedBox(width: 14),
        const Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BROKA Escrow Protection',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 15, fontWeight: FontWeight.w800)),
            SizedBox(height: 3),
            Text(
              'Your money is held safely until you confirm delivery. '
              'Zero risk of losing funds to a bad seller.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            ),
          ],
        )),
      ]),
    ),
  );

  // ── Escrow flow steps ─────────────────────────────────────────────────────

  Widget _buildEscrowFlow() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 14),
        child: Text('HOW ESCROW WORKS',
            style: TextStyle(
                color: BrokaColors.textLow, fontSize: 10,
                fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      ),
      ...List.generate(_escrowSteps.length, (i) {
        final step = _escrowSteps[i];
        final isLast = i == _escrowSteps.length - 1;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left: number + connector line
            Column(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: step.color.withOpacity(0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: step.color.withOpacity(0.5), width: 1.5),
                ),
                child: Center(child: Icon(step.icon,
                    color: step.color, size: 16)),
              ),
              if (!isLast)
                Container(
                  width: 2, height: 44,
                  color: BrokaColors.border,
                ),
            ]),
            const SizedBox(width: 14),
            // Right: text
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: isLast ? 0 : 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: step.color.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('Step ${i + 1}',
                            style: TextStyle(
                                color: step.color,
                                fontSize: 9,
                                fontWeight: FontWeight.w800)),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(step.title,
                        style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(step.body,
                        style: const TextStyle(
                            color: BrokaColors.textMid,
                            fontSize: 12, height: 1.5)),
                  ],
                ),
              ),
            ),
          ],
        );
      }),
    ]),
  );

  // ── Section label ─────────────────────────────────────────────────────────

  Widget _buildSectionLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 28, 16, 12),
    child: Text(label,
        style: const TextStyle(
            color: BrokaColors.textLow, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 1.2)),
  );

  // ── Safety tip card ───────────────────────────────────────────────────────

  Widget _buildTipCard(int index) {
    final tip      = _safetyTips[index];
    final expanded = _expandedTip == index;
    final isHigh   = tip.risk.startsWith('HIGH');

    return GestureDetector(
      onTap: () => setState(() =>
          _expandedTip = expanded ? -1 : index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        decoration: BoxDecoration(
          color: expanded
              ? tip.color.withOpacity(0.08)
              : BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: expanded
                ? tip.color.withOpacity(0.4)
                : BrokaColors.border,
            width: expanded ? 1.5 : 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: tip.color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(tip.icon, color: tip.color, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tip.title,
                        style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(tip.shortDesc,
                        style: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 11)),
                  ],
                )),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: BrokaColors.textLow, size: 20,
                ),
              ]),
            ),
            if (expanded) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 1,
                      color: tip.color.withOpacity(0.2),
                      margin: const EdgeInsets.only(bottom: 12),
                    ),
                    Text(tip.fullDesc,
                        style: const TextStyle(
                            color: BrokaColors.textMid,
                            fontSize: 13, height: 1.6)),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isHigh
                            ? Colors.redAccent.withOpacity(0.1)
                            : Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isHigh
                              ? Colors.redAccent.withOpacity(0.3)
                              : Colors.orange.withOpacity(0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isHigh
                                ? Icons.warning_rounded
                                : Icons.info_outline_rounded,
                            size: 11,
                            color: isHigh
                                ? Colors.redAccent
                                : Colors.orange,
                          ),
                          const SizedBox(width: 5),
                          Text(tip.risk,
                              style: TextStyle(
                                color: isHigh
                                    ? Colors.redAccent
                                    : Colors.orange,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              )),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Bottom CTA ────────────────────────────────────────────────────────────

  Widget _buildBottomCta() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            BrokaColors.neonGreen.withOpacity(0.12),
            BrokaColors.neonBlue.withOpacity(0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: BrokaColors.neonGreen.withOpacity(0.35), width: 1.5),
      ),
      child: Column(children: [
        const Icon(Icons.verified_user_rounded,
            color: BrokaColors.neonGreen, size: 36),
        const SizedBox(height: 12),
        const Text('You\'re now a BROKA-savvy buyer',
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 17, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text(
          'Every transaction through BROKA is protected by escrow, '
          'monitored by Zeno AI, and backed by our dispute resolution system. '
          'Trade with confidence.',
          style: TextStyle(
              color: BrokaColors.textMid, fontSize: 13, height: 1.5),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.neonGreen, Color(0xFF059669)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                    color: BrokaColors.neonGreen.withOpacity(0.3),
                    blurRadius: 16, offset: const Offset(0, 4)),
              ],
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.shopping_bag_rounded,
                    color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Start Shopping Safely',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      ]),
    ),
  );
}

// ── Data classes ───────────────────────────────────────────────────────────────

class _EscrowStep {
  final IconData icon;
  final Color    color;
  final String   title;
  final String   body;
  const _EscrowStep({
    required this.icon, required this.color,
    required this.title, required this.body,
  });
}

class _SafetyTip {
  final IconData icon;
  final Color    color;
  final String   title;
  final String   shortDesc;
  final String   fullDesc;
  final String   risk;
  const _SafetyTip({
    required this.icon, required this.color, required this.title,
    required this.shortDesc, required this.fullDesc, required this.risk,
  });
}
