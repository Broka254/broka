// Editing one part of an open store, with the same page the setup wizard
// used for it. Returns the updated store when saved.
import 'package:flutter/material.dart';

import '../../../core/utils/result.dart';
import '../../../widgets/wizard_scaffold.dart';
import '../domain/models/store.dart';
import 'setup/store_setup_controller.dart';
import 'setup/store_setup_steps.dart';

class StoreEditScreen extends StatefulWidget {
  const StoreEditScreen({
    super.key,
    required this.store,
    required this.step,
    this.controller,
    this.animateBackground = true,
  });

  final Store store;
  final StoreSetupStep step;

  /// For tests; normally made from [store].
  final StoreSetupController? controller;
  final bool animateBackground;

  @override
  State<StoreEditScreen> createState() => _StoreEditScreenState();
}

class _StoreEditScreenState extends State<StoreEditScreen> {
  late final StoreSetupController c =
      widget.controller ?? StoreSetupController.edit(widget.store);
  String? _error;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    // The email page offers the account's own verified address.
    if (widget.step == StoreSetupStep.email) _loadOwner();
  }

  Future<void> _loadOwner() async {
    final result = await c.repository.getOwnerProfile();
    result.fold(onSuccess: (o) => c.owner = o, onFailure: (_, __) {});
    if (mounted) setState(() {});
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final (store, problem) = await c.saveSection(widget.step);
    if (!mounted) return;
    if (store != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
      Navigator.of(context).pop(store);
      return;
    }
    setState(() => _error = problem?.message);
  }

  Widget _content() => switch (widget.step) {
        StoreSetupStep.name => NameStep(c),
        StoreSetupStep.category => CategoryStep(c),
        StoreSetupStep.location => LocationStep(c),
        StoreSetupStep.logo => LogoStep(c),
        StoreSetupStep.photos => PhotosStep(c),
        StoreSetupStep.email => EmailStep(c, onError: (e) => setState(() => _error = e)),
        _ => const SizedBox.shrink(),
      };

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      flowTitle: widget.store.name,
      position: 0,
      total: 1,
      title: stepTitle(widget.step),
      subtitle: stepSubtitle(widget.step),
      onNext: _save,
      nextLabel: 'Save',
      nextIcon: Icons.check_rounded,
      loading: c.busy,
      error: _error,
      animateBackground: widget.animateBackground,
      child: _content(),
    );
  }
}
