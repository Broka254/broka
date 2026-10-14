// BROKA — Phone number field with a country-code selector.
//
// Replaces the plain "Phone Number" text field on the auth screens. The
// dial code lives in a tappable segment on the left (flag + code + chevron),
// separated from the number itself by a hairline rule.
//
// The dial code is owned by the PARENT, not by this widget. The auth screen
// needs the composed E.164 number in three separate places (request OTP,
// verify OTP, register) and a selection buried in this widget's private
// state would have to be lifted out again for all three.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';

/// One entry in the dial-code picker.
class PhoneCountry {
  const PhoneCountry(this.name, this.dialCode, this.flag, this.nsnLength);

  final String name;

  /// Including the leading '+', e.g. "+254".
  final String dialCode;

  /// Emoji flag. Android and iOS both render these natively, which avoids
  /// shipping and scaling a set of flag assets for a single control.
  final String flag;

  /// Expected national significant number length (digits after the dial
  /// code). Used only to decide when a number looks complete enough to
  /// enable the submit button.
  final int nsnLength;
}

/// East Africa first, since that is BROKA's market. Kenya leads because it
/// is the default and by far the most common.
const List<PhoneCountry> kPhoneCountries = [
  PhoneCountry('Kenya', '+254', '🇰🇪', 9),
  PhoneCountry('Uganda', '+256', '🇺🇬', 9),
  PhoneCountry('Tanzania', '+255', '🇹🇿', 9),
  PhoneCountry('Rwanda', '+250', '🇷🇼', 9),
  PhoneCountry('Burundi', '+257', '🇧🇮', 8),
  PhoneCountry('South Sudan', '+211', '🇸🇸', 9),
  PhoneCountry('Ethiopia', '+251', '🇪🇹', 9),
  PhoneCountry('Somalia', '+252', '🇸🇴', 8),
  PhoneCountry('DR Congo', '+243', '🇨🇩', 9),
];

PhoneCountry countryForDialCode(String dialCode) => kPhoneCountries.firstWhere(
      (c) => c.dialCode == dialCode,
      orElse: () => kPhoneCountries.first,
    );

/// Composes a dial code and a locally-typed number into E.164.
///
/// Kenyan numbers are habitually written as `0706462869`, and people type
/// them that way even with `+254` already showing. Dropping a single leading
/// zero is what makes `+254` + `0706462869` resolve to `+254706462869`
/// rather than the invalid `+2540706462869`.
String composeE164(String dialCode, String localNumber) {
  var digits = localNumber.replaceAll(RegExp(r'[^0-9]'), '');
  while (digits.startsWith('0')) {
    digits = digits.substring(1);
  }
  return '$dialCode$digits';
}

class CountryPhoneField extends StatefulWidget {
  const CountryPhoneField({
    super.key,
    required this.controller,
    required this.dialCode,
    required this.onDialCodeChanged,
    this.onChanged,
    this.autofocus = false,
    this.hintText = 'Phone number',
    this.enabled = true,
  });

  final TextEditingController controller;
  final String dialCode;
  final ValueChanged<String> onDialCodeChanged;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final String hintText;
  final bool enabled;

  @override
  State<CountryPhoneField> createState() => _CountryPhoneFieldState();
}

class _CountryPhoneFieldState extends State<CountryPhoneField> {
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode()..addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  Future<void> _pickCountry(BuildContext context) async {
    FocusScope.of(context).unfocus();
    final picked = await showModalBottomSheet<PhoneCountry>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _CountrySheet(selected: widget.dialCode),
    );
    if (picked != null) widget.onDialCodeChanged(picked.dialCode);
  }

  @override
  Widget build(BuildContext context) {
    final country = countryForDialCode(widget.dialCode);
    final focused = _focus.hasFocus;

    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: focused
              ? BrokaColors.gold.withOpacity(0.85)
              : BrokaColors.border.withOpacity(0.7),
          width: focused ? 1.5 : 1,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: BrokaColors.gold.withOpacity(0.22),
                  blurRadius: 18,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          // ── Dial-code segment ────────────────────────────────────────
          InkWell(
            onTap: widget.enabled ? () => _pickCountry(context) : null,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(country.flag, style: const TextStyle(fontSize: 22)),
                  const SizedBox(width: 8),
                  Text(
                    country.dialCode,
                    style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: BrokaColors.textMid,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),

          // ── Separator ────────────────────────────────────────────────
          Container(
            width: 1,
            height: 26,
            color: BrokaColors.border.withOpacity(0.8),
          ),

          // ── Number ───────────────────────────────────────────────────
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              autofocus: widget.autofocus,
              keyboardType: TextInputType.phone,
              onChanged: widget.onChanged,
              // The national part never contains a '+'; the dial code
              // segment owns that. Allowing one here produces numbers like
              // "+254+254..." when someone pastes a full international
              // number on top of a selected country.
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                LengthLimitingTextInputFormatter(15),
              ],
              autofillHints: const [AutofillHints.telephoneNumberNational],
              style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                prefixIcon: const Icon(
                  Icons.phone_outlined,
                  color: BrokaColors.textMid,
                  size: 18,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 34,
                  minHeight: 20,
                ),
                hintText: widget.hintText,
                hintStyle: const TextStyle(
                  color: BrokaColors.textMid,
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountrySheet extends StatelessWidget {
  const _CountrySheet({required this.selected});

  final String selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0B1020),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: BrokaColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Select country',
              style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: kPhoneCountries.length,
                itemBuilder: (_, i) {
                  final c = kPhoneCountries[i];
                  final isSelected = c.dialCode == selected;
                  return ListTile(
                    onTap: () => Navigator.pop(context, c),
                    leading: Text(c.flag, style: const TextStyle(fontSize: 26)),
                    title: Text(
                      c.name,
                      style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 15,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          c.dialCode,
                          style: const TextStyle(
                            color: BrokaColors.textMid,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.check_circle_rounded,
                            color: BrokaColors.gold,
                            size: 18,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
