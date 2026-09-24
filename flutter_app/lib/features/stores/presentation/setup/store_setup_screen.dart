// Store setup: one question per screen, on the constellation background,
// with the draft kept on the phone after every change.
import 'package:flutter/material.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../widgets/constellation_background.dart';
import '../../../../core/utils/result.dart';
import '../../../../widgets/wizard_scaffold.dart';
import '../store_launched_screen.dart';
import 'store_setup_controller.dart';
import 'store_setup_steps.dart';

class StoreSetupScreen extends StatefulWidget {
  const StoreSetupScreen({super.key, this.controller, this.animateBackground = true});

  /// For tests; normally the screen makes its own.
  final StoreSetupController? controller;
  final bool animateBackground;

  @override
  State<StoreSetupScreen> createState() => _StoreSetupScreenState();
}

class _StoreSetupScreenState extends State<StoreSetupScreen> {
  late final StoreSetupController c = widget.controller ?? StoreSetupController();
  int _index = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _load();
  }

  Future<void> _load() async {
    await c.load();
    if (!mounted) return;
    // Someone who already has a store has nothing to set up.
    if (c.loadError == null) {
      final mine = await c.repository.getMyStore();
      if (!mounted) return;
      final store = mine.fold(onSuccess: (s) => s, onFailure: (_, __) => null);
      if (store != null) {
        await StoreSetupController.discardDraft();
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/store-manage');
      }
    }
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

  List<StoreSetupStep> get _steps => c.steps;
  StoreSetupStep get _step => _steps[_index.clamp(0, _steps.length - 1)];

  void _goTo(StoreSetupStep step) {
    final i = _steps.indexOf(step);
    if (i >= 0) setState(() { _index = i; _error = null; });
  }

  void _back() {
    if (_index == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() { _index--; _error = null; });
  }

  Future<void> _next() async {
    FocusScope.of(context).unfocus();
    final step = _step;
    if (step == StoreSetupStep.business && !c.businessDone) {
      final problem = await c.upgrade();
      if (!mounted) return;
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
    }
    if (step == StoreSetupStep.review) {
      await _launch();
      return;
    }
    final problem = c.validate(step);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    await c.saveDraft();
    if (!mounted) return;
    setState(() { _index = (_index + 1).clamp(0, _steps.length - 1); _error = null; });
  }

  Future<void> _launch() async {
    final (store, problem) = await c.launch();
    if (!mounted) return;
    if (store != null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => StoreLaunchedScreen(store: store)));
      return;
    }
    if (problem?.step != null) _goTo(problem!.step!);
    setState(() => _error = problem?.message ?? 'Something went wrong. Try again.');
  }

  String _nextLabel() {
    switch (_step) {
      case StoreSetupStep.business:
        return c.businessDone ? 'Continue' : 'Save and continue';
      case StoreSetupStep.logo:
        return c.logo == null ? 'Skip for now' : 'Continue';
      case StoreSetupStep.photos:
        return c.cover == null && c.photos.isEmpty ? 'Skip for now' : 'Continue';
      case StoreSetupStep.email:
        return c.email.trim().isEmpty ? 'Skip' : 'Continue';
      case StoreSetupStep.review:
        return 'Open my store';
      default:
        return 'Continue';
    }
  }

  Widget _content() => switch (_step) {
        StoreSetupStep.business => BusinessStep(c),
        StoreSetupStep.name => NameStep(c),
        StoreSetupStep.link => LinkStep(c),
        StoreSetupStep.category => CategoryStep(c),
        StoreSetupStep.location => LocationStep(c),
        StoreSetupStep.logo => LogoStep(c),
        StoreSetupStep.photos => PhotosStep(c),
        StoreSetupStep.email => EmailStep(c, onError: (e) => setState(() => _error = e)),
        StoreSetupStep.review => ReviewStep(c, onEdit: _goTo),
      };

  @override
  Widget build(BuildContext context) {
    if (c.loading || c.loadError != null) return _loadingOrError();
    return PopScope(
      canPop: _index == 0 && !c.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !c.busy) _back();
      },
      child: WizardScaffold(
        flowTitle: 'Set up your store',
        position: _index,
        total: _steps.length,
        title: stepTitle(_step),
        subtitle: stepSubtitle(_step),
        onBack: _index > 0 ? _back : null,
        onNext: _next,
        nextLabel: _nextLabel(),
        nextIcon: _step == StoreSetupStep.review
            ? Icons.rocket_launch_rounded
            : Icons.arrow_forward_rounded,
        loading: c.busy,
        error: _error,
        animateBackground: widget.animateBackground,
        child: KeyedSubtree(key: ValueKey(_step), child: _content()),
      ),
    );
  }

  Widget _loadingOrError() {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          child: Stack(children: [
            Positioned(
              top: 8, left: 12,
              child: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            Center(
              child: c.loading
                  ? const CircularProgressIndicator(color: BrokaColors.gold)
                  : Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.cloud_off_rounded, color: BrokaColors.textMid, size: 40),
                        const SizedBox(height: 12),
                        Text(c.loadError!, textAlign: TextAlign.center,
                            style: const TextStyle(color: BrokaColors.textMid)),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _load,
                          style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold),
                          child: const Text('Try again'),
                        ),
                      ]),
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
