// The pages of the store setup wizard. Each is one question, sized for a
// phone, and reused as-is by the store's settings pages.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../services/photo_upload_tracker.dart';
import '../../../../widgets/broka_image.dart';
import '../../../../widgets/otp_code_field.dart';
import '../../../categories/domain/category_visual.dart';
import '../../domain/kenya_locations.dart';
import '../../domain/store_categories.dart';
import 'store_setup_controller.dart';

// ── Titles ───────────────────────────────────────────────────────────────────

String stepTitle(StoreSetupStep step) => switch (step) {
      StoreSetupStep.business => 'Your business',
      StoreSetupStep.name => 'Name your store',
      StoreSetupStep.link => 'Choose your link',
      StoreSetupStep.category => 'What you sell',
      StoreSetupStep.location => 'Where you are',
      StoreSetupStep.logo => 'Your logo',
      StoreSetupStep.photos => 'Store photos',
      StoreSetupStep.email => 'Business email',
      StoreSetupStep.review => 'Ready to open',
    };

String stepSubtitle(StoreSetupStep step) => switch (step) {
      StoreSetupStep.business =>
        'Online stores are for businesses. This also makes you a long-term seller.',
      StoreSetupStep.name => 'Buyers see this at the top of your store',
      StoreSetupStep.link => 'Share it on WhatsApp, TikTok, Instagram and flyers',
      StoreSetupStep.category => 'Buyers find your store under this category',
      StoreSetupStep.location => 'So nearby buyers can find you',
      StoreSetupStep.logo => 'Optional - a square image works best',
      StoreSetupStep.photos => 'Optional - show buyers your shop',
      StoreSetupStep.email => 'Optional - where order updates go',
      StoreSetupStep.review => 'Check everything, then open your store',
    };

// ── Shared bits ──────────────────────────────────────────────────────────────

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.icon = Icons.info_outline_rounded, this.color});
  final String text;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? BrokaColors.textMid;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: (color ?? BrokaColors.gold).withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: (color ?? BrokaColors.gold).withOpacity(0.25)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color ?? BrokaColors.gold),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: c, fontSize: 12.5, height: 1.45))),
      ]),
    );
  }
}

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(text.toUpperCase(),
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 11,
              fontWeight: FontWeight.w700, letterSpacing: 1.1)),
    );

/// A text field that keeps its own controller in step with the wizard's
/// value, without fighting the cursor while the person types.
class _SyncedField extends StatefulWidget {
  const _SyncedField({
    required this.value,
    required this.onChanged,
    required this.label,
    this.icon,
    this.hint,
    this.maxLength,
    this.maxLines = 1,
    this.keyboardType,
    this.autofocus = false,
    this.inputFormatters,
    this.prefixText,
    this.textCapitalization = TextCapitalization.none,
    this.fieldKey,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final IconData? icon;
  final String? hint;
  final int? maxLength;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool autofocus;
  final List<TextInputFormatter>? inputFormatters;
  final String? prefixText;
  final TextCapitalization textCapitalization;
  final Key? fieldKey;

  @override
  State<_SyncedField> createState() => _SyncedFieldState();
}

class _SyncedFieldState extends State<_SyncedField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_SyncedField old) {
    super.didUpdateWidget(old);
    if (widget.value != _ctrl.text) {
      _ctrl.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: widget.fieldKey,
        controller: _ctrl,
        onChanged: widget.onChanged,
        autofocus: widget.autofocus,
        maxLength: widget.maxLength,
        maxLines: widget.maxLines,
        minLines: widget.maxLines > 1 ? 3 : 1,
        keyboardType: widget.keyboardType,
        inputFormatters: widget.inputFormatters,
        textCapitalization: widget.textCapitalization,
        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16),
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          prefixText: widget.prefixText,
          prefixStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 16),
          prefixIcon: widget.icon == null
              ? null
              : Icon(widget.icon, color: BrokaColors.textLow, size: 18),
          counterStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 11),
        ),
      );
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.selected, required this.onSelected});
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 10, children: [
      for (final name in StoreCategories.all)
        _chip(name, CategoryVisuals.resolve(name), selected == name),
    ]);
  }

  Widget _chip(String name, CategoryVisual visual, bool isSelected) => Semantics(
        selected: isSelected,
        button: true,
        child: GestureDetector(
          onTap: () => onSelected(name),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? visual.gradient.first.withOpacity(0.22)
                  : BrokaColors.bgCard.withOpacity(0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected ? BrokaColors.gold : BrokaColors.border.withOpacity(0.8),
                width: isSelected ? 1.5 : 1,
              ),
              boxShadow: isSelected
                  ? [BoxShadow(color: BrokaColors.gold.withOpacity(0.22),
                      blurRadius: 14, spreadRadius: -4)]
                  : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(visual.emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: isSelected ? BrokaColors.textHigh : BrokaColors.textMid,
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
              ),
            ]),
          ),
        ),
      );
}

// ── Business details (upgrade) ───────────────────────────────────────────────

class BusinessStep extends StatelessWidget {
  const BusinessStep(this.c, {super.key});
  final StoreSetupController c;

  @override
  Widget build(BuildContext context) {
    if (c.businessDone) {
      return const _Hint('Business details saved - you are now a long-term seller. '
          'Continue to set up your store.',
          icon: Icons.verified_rounded, color: BrokaColors.success);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SyncedField(
        value: c.businessName,
        onChanged: c.setBusinessName,
        label: 'Business name',
        icon: Icons.storefront_outlined,
        maxLength: 60,
        textCapitalization: TextCapitalization.words,
      ),
      const SizedBox(height: 12),
      _label('What does it sell?'),
      _CategoryChips(selected: c.businessCategory, onSelected: c.setBusinessCategory),
      const SizedBox(height: 22),
      _SyncedField(
        value: c.businessLocation,
        onChanged: c.setBusinessLocation,
        label: 'Where is it?',
        hint: 'e.g. Moi Avenue, Nairobi',
        icon: Icons.place_outlined,
        maxLength: 80,
        textCapitalization: TextCapitalization.words,
      ),
      const SizedBox(height: 8),
      const _Hint('Buying stays exactly the same. Your business name appears on '
          'your products, so buyers know who they are dealing with.'),
    ]);
  }
}

// ── Name ─────────────────────────────────────────────────────────────────────

class NameStep extends StatelessWidget {
  const NameStep(this.c, {super.key});
  final StoreSetupController c;

  @override
  Widget build(BuildContext context) {
    final name = c.name.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SyncedField(
        fieldKey: const Key('store-name-field'),
        value: c.name,
        onChanged: c.setName,
        label: 'Store name',
        hint: 'e.g. Clanix Electronics',
        icon: Icons.storefront_outlined,
        maxLength: StoreSetupController.maxNameLength,
        autofocus: c.name.isEmpty,
        textCapitalization: TextCapitalization.words,
      ),
      const SizedBox(height: 18),
      _label('Preview'),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
        ),
        child: Row(children: [
          _InitialBadge(name),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name.isEmpty ? 'Your store' : name,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: name.isEmpty ? BrokaColors.textLow : BrokaColors.textHigh,
                    fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      const _Hint('You can change the name later. Your link is chosen next and '
          "can't change, so pick a name you're happy to build on."),
    ]);
  }
}

class _InitialBadge extends StatelessWidget {
  const _InitialBadge(this.name, {this.size = 48});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.28),
          gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6)]),
        ),
        child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: TextStyle(color: Colors.white, fontSize: size * 0.42,
                fontWeight: FontWeight.w800)),
      );
}

// ── Link ─────────────────────────────────────────────────────────────────────

class _LowerCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toLowerCase());
}

class LinkStep extends StatelessWidget {
  const LinkStep(this.c, {super.key});
  final StoreSetupController c;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SyncedField(
        fieldKey: const Key('store-link-field'),
        value: c.slug,
        onChanged: c.setSlug,
        label: 'Store link',
        prefixText: c.linkPrefix,
        maxLength: StoreSetupController.maxLinkLength,
        keyboardType: TextInputType.url,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9-]')),
          _LowerCase(),
        ],
      ),
      const SizedBox(height: 4),
      _LinkStatusRow(c),
      const SizedBox(height: 18),
      const _Hint(
        "Choose carefully: your link can't be changed after your store opens. "
        "It goes on your posts, your flyers and your store's QR code. "
        'Letters, numbers and hyphens only.',
        icon: Icons.lock_clock_outlined,
        color: BrokaColors.warning,
      ),
    ]);
  }
}

class _LinkStatusRow extends StatelessWidget {
  const _LinkStatusRow(this.c);
  final StoreSetupController c;

  @override
  Widget build(BuildContext context) {
    Widget row(Widget lead, String text, Color color, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            lead,
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13,
                fontWeight: FontWeight.w600))),
            if (trailing != null) trailing,
          ]),
        );

    switch (c.linkStatus) {
      case LinkStatus.idle:
        return const SizedBox.shrink();
      case LinkStatus.invalid:
        return c.linkMessage == null
            ? const SizedBox.shrink()
            : row(const Icon(Icons.info_outline_rounded, size: 18, color: BrokaColors.warning),
                c.linkMessage!, BrokaColors.warning);
      case LinkStatus.checking:
        return row(const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold)),
            'Checking...', BrokaColors.textMid);
      case LinkStatus.available:
        return row(const Icon(Icons.check_circle_rounded, size: 18, color: BrokaColors.success),
            '${c.linkPrefix}${c.slug} is available', BrokaColors.success);
      case LinkStatus.unavailable:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row(const Icon(Icons.cancel_rounded, size: 18, color: BrokaColors.danger),
              c.linkMessage ?? "That link can't be used.", BrokaColors.danger),
          if (c.linkSuggestion != null) ...[
            const SizedBox(height: 10),
            ActionChip(
              key: const Key('use-suggested-link'),
              avatar: const Icon(Icons.auto_fix_high_rounded, size: 16, color: BrokaColors.gold),
              label: Text('Use ${c.linkSuggestion}'),
              labelStyle: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w600),
              backgroundColor: BrokaColors.bgCard,
              side: const BorderSide(color: BrokaColors.gold),
              onPressed: c.useSuggestedLink,
            ),
          ],
        ]);
      case LinkStatus.error:
        return row(const Icon(Icons.wifi_off_rounded, size: 18, color: BrokaColors.warning),
            c.linkMessage ?? "Couldn't check the link.", BrokaColors.warning,
            trailing: TextButton(onPressed: c.retryLinkCheck, child: const Text('Retry')));
    }
  }
}

// ── Category ─────────────────────────────────────────────────────────────────

class CategoryStep extends StatelessWidget {
  const CategoryStep(this.c, {super.key});
  final StoreSetupController c;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('Main category'),
      _CategoryChips(selected: c.category, onSelected: c.setCategory),
      const SizedBox(height: 24),
      _SyncedField(
        value: c.description,
        onChanged: c.setDescription,
        label: 'About your store (optional)',
        hint: 'What you sell, brands you stock, delivery, opening hours...',
        maxLines: 5,
        maxLength: StoreSetupController.maxDescriptionLength,
        textCapitalization: TextCapitalization.sentences,
      ),
      const SizedBox(height: 4),
      const _Hint('Products from any category can go in your store. This is the '
          'one it is listed under.'),
    ]);
  }
}

// ── Location ─────────────────────────────────────────────────────────────────

class LocationStep extends StatefulWidget {
  const LocationStep(this.c, {super.key});
  final StoreSetupController c;

  @override
  State<LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends State<LocationStep> {
  late bool _typingArea = widget.c.subcounty != null &&
      KenyaLocations.canonicalSubcounty(widget.c.county, widget.c.subcounty) == null;

  StoreSetupController get c => widget.c;

  Future<void> _pickCounty() async {
    final picked = await _pickFromList(context,
        title: 'Choose your county', options: KenyaLocations.counties, selected: c.county);
    if (picked != null) {
      setState(() => _typingArea = false);
      c.setCounty(picked);
    }
  }

  Future<void> _pickArea() async {
    const other = "My area isn't listed";
    final picked = await _pickFromList(context,
        title: 'Choose your area',
        options: [...KenyaLocations.subcountiesOf(c.county), other],
        selected: c.subcounty);
    if (picked == null) return;
    if (picked == other) {
      setState(() => _typingArea = true);
      c.setSubcounty(null);
    } else {
      setState(() => _typingArea = false);
      c.setSubcounty(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = c.owner?.businessLocation;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _PickerField(
        key: const Key('county-picker'),
        label: 'County',
        value: c.county,
        icon: Icons.map_outlined,
        onTap: _pickCounty,
      ),
      const SizedBox(height: 14),
      if (_typingArea)
        _SyncedField(
          value: c.subcounty ?? '',
          onChanged: (v) => c.setSubcounty(v),
          label: 'Area / subcounty',
          icon: Icons.place_outlined,
          maxLength: 80,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        )
      else
        _PickerField(
          key: const Key('area-picker'),
          label: 'Area / subcounty',
          value: c.subcounty,
          icon: Icons.place_outlined,
          enabled: c.county != null,
          onTap: _pickArea,
        ),
      const SizedBox(height: 14),
      _SyncedField(
        value: c.landmark,
        onChanged: c.setLandmark,
        label: 'Street, building or landmark (optional)',
        hint: hint != null && hint.isNotEmpty ? 'e.g. $hint' : 'e.g. Moi Avenue, Imenti House',
        icon: Icons.signpost_outlined,
        maxLength: 160,
        textCapitalization: TextCapitalization.sentences,
      ),
    ]);
  }
}

class _PickerField extends StatelessWidget {
  const _PickerField({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.enabled = true,
  });
  final String label;
  final String? value;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: Icon(icon, color: BrokaColors.textLow, size: 18),
            suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded, color: BrokaColors.textMid),
          ),
          isEmpty: value == null || value!.isEmpty,
          child: Text(value ?? '',
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        ),
      ),
    );
  }
}

/// A searchable list in a bottom sheet. Returns the chosen option.
Future<String?> _pickFromList(
  BuildContext context, {
  required String title,
  required List<String> options,
  String? selected,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BrokaColors.bgMid,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => _SearchList(title: title, options: options, selected: selected),
  );
}

class _SearchList extends StatefulWidget {
  const _SearchList({required this.title, required this.options, this.selected});
  final String title;
  final List<String> options;
  final String? selected;

  @override
  State<_SearchList> createState() => _SearchListState();
}

class _SearchListState extends State<_SearchList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.options
        : widget.options.where((o) => o.toLowerCase().contains(q)).toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(
                color: BrokaColors.border, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Row(children: [
                Expanded(child: Text(widget.title, style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800))),
              ]),
            ),
            if (widget.options.length > 8)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: TextField(
                  autofocus: false,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: BrokaColors.textHigh),
                  decoration: const InputDecoration(
                    hintText: 'Search',
                    prefixIcon: Icon(Icons.search_rounded, color: BrokaColors.textLow),
                  ),
                ),
              ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No matches',
                      style: TextStyle(color: BrokaColors.textLow)))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final o = shown[i];
                        final isSelected = o == widget.selected;
                        return ListTile(
                          title: Text(o, style: TextStyle(
                              color: isSelected ? BrokaColors.gold : BrokaColors.textHigh,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                          trailing: isSelected
                              ? const Icon(Icons.check_rounded, color: BrokaColors.gold)
                              : null,
                          onTap: () => Navigator.pop(context, o),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Images ───────────────────────────────────────────────────────────────────

/// Asks camera or gallery, then returns the picked file (or null).
Future<File?> pickStoreImage(BuildContext context, {ImagePicker? picker}) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: BrokaColors.bgMid,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (sheet) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined, color: BrokaColors.gold),
          title: const Text('Take a photo', style: TextStyle(color: BrokaColors.textHigh)),
          onTap: () => Navigator.pop(sheet, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined, color: BrokaColors.gold),
          title: const Text('Choose from gallery', style: TextStyle(color: BrokaColors.textHigh)),
          onTap: () => Navigator.pop(sheet, ImageSource.gallery),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (source == null) return null;
  try {
    final x = await (picker ?? ImagePicker()).pickImage(
      source: source, maxWidth: 2400, maxHeight: 2400, imageQuality: 90,
    );
    return x == null ? null : File(x.path);
  } on PlatformException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          e.code.contains('denied')
              ? 'BROKA needs permission to use your ${source == ImageSource.camera ? 'camera' : 'photos'}. '
                'Allow it in your phone settings.'
              : "Couldn't open the ${source == ImageSource.camera ? 'camera' : 'gallery'}.")));
    }
    return null;
  }
}

/// One image in the draft, with its upload progress or failure over it.
class _DraftImageTile extends StatelessWidget {
  const _DraftImageTile({
    required this.image,
    required this.state,
    required this.onRemove,
    required this.onRetry,
    this.radius = 14,
  });

  final DraftImage image;
  final PhotoUploadState? state;
  final VoidCallback onRemove;
  final VoidCallback onRetry;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final Widget picture = image.hasLocalFile
        ? Image.file(File(image.path!), fit: BoxFit.cover)
        : BrokaImage(image.url, fit: BoxFit.cover);
    final failed = state?.status == PhotoUploadStatus.failed;
    final uploading = state?.status == PhotoUploadStatus.uploading;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(fit: StackFit.expand, children: [
        picture,
        if (uploading)
          Container(
            color: Colors.black45,
            alignment: Alignment.center,
            child: SizedBox(
              width: 34, height: 34,
              child: CircularProgressIndicator(
                value: (state!.progress > 0 && state!.progress < 1) ? state!.progress : null,
                strokeWidth: 3, color: Colors.white),
            ),
          ),
        if (failed)
          Material(
            color: Colors.black54,
            child: InkWell(
              onTap: onRetry,
              child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.refresh_rounded, color: Colors.white),
                SizedBox(height: 4),
                Text('Retry', style: TextStyle(color: Colors.white, fontSize: 12,
                    fontWeight: FontWeight.w700)),
              ])),
            ),
          ),
        Positioned(
          top: 6, right: 6,
          child: Semantics(
            button: true,
            label: 'Remove image',
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _AddImageTile extends StatelessWidget {
  const _AddImageTile({required this.label, required this.icon, required this.onTap,
      this.radius = 14, super.key});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final double radius;

  @override
  Widget build(BuildContext context) => Material(
        color: BrokaColors.bgCard.withOpacity(0.55),
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: BrokaColors.gold.withOpacity(0.45), width: 1.2),
            ),
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: BrokaColors.gold, size: 28),
              const SizedBox(height: 6),
              Text(label, textAlign: TextAlign.center,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ])),
          ),
        ),
      );
}

class LogoStep extends StatelessWidget {
  const LogoStep(this.c, {super.key});
  final StoreSetupController c;

  @override
  Widget build(BuildContext context) {
    final logo = c.logo;
    Future<void> pick() async {
      final f = await pickStoreImage(context);
      if (f != null) c.setLogo(f);
    }

    return Column(children: [
      const SizedBox(height: 8),
      Center(
        child: SizedBox(
          width: 168, height: 168,
          child: logo == null
              ? _AddImageTile(key: const Key('add-logo'), label: 'Add logo',
                  icon: Icons.add_a_photo_outlined, onTap: pick, radius: 36)
              : _DraftImageTile(
                  image: logo,
                  state: c.uploadState(logo, c.logoUploads),
                  onRemove: c.removeLogo,
                  onRetry: c.retryUploads,
                  radius: 36,
                ),
        ),
      ),
      if (logo != null) ...[
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: pick,
          icon: const Icon(Icons.swap_horiz_rounded, color: BrokaColors.gold),
          label: const Text('Change logo', style: TextStyle(color: BrokaColors.gold)),
        ),
      ],
      const SizedBox(height: 22),
      const _Hint('Your logo shows on your store, next to your products and on '
          "your store's share page. No logo? Skip this - your store's initial is "
          'used until you add one.'),
    ]);
  }
}

class PhotosStep extends StatelessWidget {
  const PhotosStep(this.c, {super.key});
  final StoreSetupController c;

  @override
  Widget build(BuildContext context) {
    final cover = c.cover;
    Future<void> pickCover() async {
      final f = await pickStoreImage(context);
      if (f != null) c.setCover(f);
    }

    Future<void> addPhoto() async {
      final f = await pickStoreImage(context);
      if (f != null) c.addPhoto(f);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('Cover photo'),
      AspectRatio(
        aspectRatio: 16 / 9,
        child: cover == null
            ? _AddImageTile(key: const Key('add-cover'),
                label: 'Add a wide photo for the top of your store',
                icon: Icons.panorama_outlined, onTap: pickCover)
            : _DraftImageTile(
                image: cover,
                state: c.uploadState(cover, c.coverUploads),
                onRemove: c.removeCover,
                onRetry: c.retryUploads,
              ),
      ),
      const SizedBox(height: 24),
      _label('Shop photos (${c.photos.length} of ${StoreSetupController.maxPhotos})'),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: [
          for (var i = 0; i < c.photos.length; i++)
            _DraftImageTile(
              image: c.photos[i],
              state: c.uploadState(c.photos[i], c.photoUploads),
              onRemove: () => c.removePhoto(i),
              onRetry: c.retryUploads,
            ),
          if (c.canAddPhoto)
            _AddImageTile(key: const Key('add-photo'), label: 'Add photo',
                icon: Icons.add_rounded, onTap: addPhoto),
        ],
      ),
      const SizedBox(height: 18),
      const _Hint('Your shop front, shelves, team - photos of a real place build '
          'trust with buyers who have never visited.'),
    ]);
  }
}

// ── Email ────────────────────────────────────────────────────────────────────

class EmailStep extends StatefulWidget {
  const EmailStep(this.c, {super.key, required this.onError});
  final StoreSetupController c;
  final ValueChanged<String?> onError;

  @override
  State<EmailStep> createState() => _EmailStepState();
}

class _EmailStepState extends State<EmailStep> {
  final _code = TextEditingController();
  StoreSetupController get c => widget.c;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    widget.onError(await c.sendEmailCode());
  }

  Future<void> _verify([String? code]) async {
    final problem = await c.verifyEmailCode(code ?? _code.text);
    widget.onError(problem);
    if (problem != null) _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SyncedField(
        fieldKey: const Key('business-email-field'),
        value: c.email,
        onChanged: (v) {
          c.setEmail(v);
          widget.onError(null);
        },
        label: 'Business email',
        hint: 'e.g. sales@yourbusiness.co.ke',
        icon: Icons.alternate_email_rounded,
        keyboardType: TextInputType.emailAddress,
        maxLength: 254,
      ),
      if (c.canUseAccountEmail) ...[
        ActionChip(
          avatar: const Icon(Icons.verified_rounded, size: 16, color: BrokaColors.success),
          label: Text('Use ${c.owner!.email}'),
          labelStyle: const TextStyle(color: BrokaColors.textHigh),
          backgroundColor: BrokaColors.bgCard,
          side: const BorderSide(color: BrokaColors.border),
          onPressed: c.useAccountEmail,
        ),
        const SizedBox(height: 12),
      ],
      if (c.email.trim().isNotEmpty) _verification(),
      const SizedBox(height: 18),
      const _Hint('Order updates and receipts go here, and buyers see it on your '
          "store once it's verified. We never show your phone number. Skip this "
          'if you do not have one - you can add it later.'),
    ]);
  }

  Widget _verification() {
    if (c.emailVerified) {
      return const Row(children: [
        Icon(Icons.verified_rounded, color: BrokaColors.success, size: 20),
        SizedBox(width: 8),
        Text('Verified', style: TextStyle(color: BrokaColors.success,
            fontWeight: FontWeight.w700)),
      ]);
    }
    if (!c.emailCodeSent) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          key: const Key('send-email-code'),
          onPressed: c.busy || !c.emailLooksValid ? null : _send,
          icon: const Icon(Icons.send_rounded, size: 18),
          label: const Text('Send verification code'),
          style: OutlinedButton.styleFrom(
            foregroundColor: BrokaColors.gold,
            side: const BorderSide(color: BrokaColors.gold),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Enter the code we sent to ${c.email.trim()}',
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
      if (c.debugEmailCode != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Test server code: ${c.debugEmailCode}',
              style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
        ),
      const SizedBox(height: 12),
      OtpCodeField(controller: _code, onCompleted: (code) => _verify(code)),
      const SizedBox(height: 10),
      Row(children: [
        TextButton(
          onPressed: c.busy ? null : _send,
          child: const Text('Resend code', style: TextStyle(color: BrokaColors.textMid)),
        ),
        const Spacer(),
        FilledButton(
          key: const Key('verify-email-code'),
          onPressed: c.busy ? null : () => _verify(),
          style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold),
          child: c.busy
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Verify'),
        ),
      ]),
    ]);
  }
}

// ── Review ───────────────────────────────────────────────────────────────────

class ReviewStep extends StatelessWidget {
  const ReviewStep(this.c, {super.key, required this.onEdit});
  final StoreSetupController c;
  final ValueChanged<StoreSetupStep> onEdit;

  @override
  Widget build(BuildContext context) {
    final cover = c.cover;
    final logo = c.logo;
    Widget image(DraftImage img) => img.hasLocalFile
        ? Image.file(File(img.path!), fit: BoxFit.cover)
        : BrokaImage(img.url, fit: BoxFit.cover);

    final uploadsFailed = [
      if (logo != null) c.uploadState(logo, c.logoUploads),
      if (cover != null) c.uploadState(cover, c.coverUploads),
      for (final p in c.photos) c.uploadState(p, c.photoUploads),
    ].any((s) => s?.status == PhotoUploadStatus.failed);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // How the top of the store will look.
      ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.7),
            border: Border.all(color: BrokaColors.border),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(
              aspectRatio: 16 / 7,
              child: cover != null
                  ? image(cover)
                  : Container(decoration: BoxDecoration(gradient: LinearGradient(
                      colors: CategoryVisuals.gradientFor(c.category)
                          .map((col) => col.withOpacity(0.6)).toList()))),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                SizedBox(
                  width: 54, height: 54,
                  child: logo != null
                      ? ClipRRect(borderRadius: BorderRadius.circular(15), child: image(logo))
                      : _InitialBadge(c.name.trim(), size: 54),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.name.trim(), maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text([
                    if (c.category != null) c.category!,
                    if ((c.subcounty ?? '').isNotEmpty) c.subcounty!,
                    if ((c.county ?? '').isNotEmpty) c.county!,
                  ].join(' · '), style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                ])),
              ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      if (uploadsFailed) ...[
        const _Hint("Some images didn't upload. Tap them to retry, or open the store "
            "and we'll try once more.",
            icon: Icons.cloud_off_rounded, color: BrokaColors.warning),
        const SizedBox(height: 12),
      ],
      _row('Name', c.name.trim(), StoreSetupStep.name),
      _row('Link', '${c.linkPrefix}${c.slug}', StoreSetupStep.link, locked: true),
      _row('Category', c.category ?? '-', StoreSetupStep.category),
      if (c.description.trim().isNotEmpty)
        _row('About', c.description.trim(), StoreSetupStep.category),
      _row('Location', [
        if ((c.landmark).trim().isNotEmpty) c.landmark.trim(),
        if ((c.subcounty ?? '').isNotEmpty) c.subcounty!,
        if ((c.county ?? '').isNotEmpty) c.county!,
      ].join(', '), StoreSetupStep.location),
      _row('Images', [
        c.logo != null ? 'Logo' : 'No logo',
        c.cover != null ? 'cover photo' : 'no cover',
        '${c.photos.length} shop photo${c.photos.length == 1 ? '' : 's'}',
      ].join(', '), StoreSetupStep.logo),
      _row('Business email',
          c.email.trim().isEmpty ? 'None' : '${c.email.trim()}${c.emailVerified ? ' (verified)' : ''}',
          StoreSetupStep.email),
    ]);
  }

  Widget _row(String label, String value, StoreSetupStep step, {bool locked = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border.withOpacity(0.7)),
          ),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label.toUpperCase(), style: const TextStyle(color: BrokaColors.textLow,
                  fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1)),
              const SizedBox(height: 3),
              Text(value, maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14)),
              if (locked)
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Text("Can't be changed after opening",
                      style: TextStyle(color: BrokaColors.warning, fontSize: 11)),
                ),
            ])),
            TextButton(onPressed: () => onEdit(step),
                child: const Text('Edit', style: TextStyle(color: BrokaColors.gold))),
          ]),
        ),
      );
}
