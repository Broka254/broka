// BROKA - the seller questions, shared.
//
// Signup asks them (lib/screens/auth_screen.dart) and so does Start selling
// (lib/screens/start_selling_screen.dart), for a buyer who decides to sell
// later: a few items, or a business - and for a business, its name, what it
// sells, where it is and what it does. One set of widgets, so the two can't
// drift into different questions, different categories or a different look.
import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;

/// What a business can say it sells. Also what buyers filter by, so signup
/// and Start selling must offer the same list.
const List<String> kBusinessCategories = [
  'Electronics', 'Wholesale', 'Clothing & Fashion', 'Supermarket',
  'Property', 'Automotive', 'Food & Beverages', 'Services', 'Other',
];

/// Mirrors the server's own composition (generate_business_display_name) so
/// a preview shows what will actually be stored, not a client-side guess.
String businessDisplayName(String name, String category, String location) =>
    [name.trim(), category.trim(), location.trim()]
        .where((p) => p.isNotEmpty)
        .join(' · ');

/// A large, tappable option card - one answer to a question the user is
/// walking through.
class SellerChoiceCard extends StatelessWidget {
  const SellerChoiceCard({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(selected ? 0.75 : 0.4),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? BrokaColors.gold
                : BrokaColors.border.withOpacity(0.7),
            width: selected ? 1.6 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: BrokaColors.gold.withOpacity(0.25),
                  blurRadius: 20, spreadRadius: -4)]
              : null,
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? BrokaColors.gold.withOpacity(0.18)
                  : BrokaColors.bgMid,
            ),
            child: Icon(icon,
                color: selected ? BrokaColors.gold : BrokaColors.textMid,
                size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(
                  color: selected ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(body, style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.45)),
            ],
          )),
          const SizedBox(width: 8),
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: selected ? BrokaColors.gold : BrokaColors.border,
            size: 20,
          ),
        ]),
      ),
    ),
  );
}

/// "What kind of seller?" - 'short_term' (a few items, no setup) or
/// 'long_term' (a business, set up now).
class SellerHorizonChoices extends StatelessWidget {
  const SellerHorizonChoices({super.key, required this.tier, required this.onChanged});

  final String tier;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Column(children: [
    SellerChoiceCard(
      key: const Key('seller-tier-short_term'),
      selected: tier == 'short_term',
      icon: Icons.sell_outlined,
      title: 'Just a few items',
      body: 'Under about 5 things — clearing out, or selling one-offs. '
            'No business setup needed.',
      onTap: () => onChanged('short_term'),
    ),
    const SizedBox(height: 12),
    SellerChoiceCard(
      key: const Key('seller-tier-long_term'),
      selected: tier == 'long_term',
      icon: Icons.business_center_outlined,
      title: "I'm running a business",
      body: 'Selling regularly on BROKA. We will set up your business '
            'name and storefront now so buyers can find you.',
      onTap: () => onChanged('long_term'),
    ),
  ]);
}

/// A one-line text field with a leading icon.
class SetupTextField extends StatelessWidget {
  const SetupTextField(
    this.controller,
    this.label,
    this.icon, {
    super.key,
    this.type = TextInputType.text,
    this.autofocus = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType type;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: type,
    autofocus: autofocus,
    onChanged: onChanged,
    style: const TextStyle(color: BrokaColors.textHigh),
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: BrokaColors.textLow, size: 18),
    ),
  );
}

/// The small explanatory line under a step's field.
class SetupHint extends StatelessWidget {
  const SetupHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(text,
        style: const TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.5)),
  );
}

/// What the business sells: the category list, and a field of its own for
/// 'Other'.
class BusinessCategoryPicker extends StatelessWidget {
  const BusinessCategoryPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.otherController,
    this.onOtherChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final TextEditingController otherController;
  final ValueChanged<String>? onOtherChanged;

  @override
  Widget build(BuildContext context) => Column(children: [
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border.withOpacity(0.7)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: const Color(0xFF0B1020),
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              color: BrokaColors.textMid),
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16),
          items: [
            for (final c in kBusinessCategories)
              DropdownMenuItem(
                value: c,
                child: Text(c, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 16)),
              ),
          ],
          // The closed button renders through this rather than reusing the
          // menu item, so the selected value is styled explicitly instead of
          // inheriting whatever DefaultTextStyle happens to be in scope —
          // the same inheritance gap that had the sign-in prompt rendering
          // in the wrong font.
          selectedItemBuilder: (_) => [
            for (final c in kBusinessCategories)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(c, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 16,
                    fontWeight: FontWeight.w500)),
              ),
          ],
          onChanged: (v) => onChanged(v ?? value),
        ),
      ),
    ),
    if (value == 'Other') ...[
      const SizedBox(height: 14),
      SetupTextField(otherController, 'Describe what you sell',
          Icons.edit_outlined, autofocus: true, onChanged: onOtherChanged),
    ],
    const SizedBox(height: 10),
    const SetupHint('This becomes part of your business name, and it is how '
        'buyers filter for what you sell.'),
  ]);
}

/// "Your business will appear as" - the name buyers will see.
class BusinessPreviewCard extends StatelessWidget {
  const BusinessPreviewCard({super.key, required this.displayName});

  final String displayName;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.6),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Your business will appear as',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      const SizedBox(height: 8),
      Text(
        displayName.isEmpty ? '—' : displayName,
        style: const TextStyle(color: BrokaColors.gold, fontSize: 20,
            fontWeight: FontWeight.w800, height: 1.3),
      ),
    ]),
  );
}

/// One part of the business on the preview step. Tapping it goes back to
/// the step that owns it, so a typo isn't three Back taps away.
class BusinessEditRow extends StatelessWidget {
  const BusinessEditRow({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.border.withOpacity(0.6)),
      ),
      child: Row(children: [
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 12)),
        ),
        Expanded(child: Text(
          value.isEmpty ? '—' : value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: BrokaColors.textHigh,
              fontSize: 13, fontWeight: FontWeight.w600),
        )),
        const SizedBox(width: 8),
        const Icon(Icons.edit_outlined, color: BrokaColors.gold, size: 16),
      ]),
    ),
  );
}
