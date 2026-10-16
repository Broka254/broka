// BROKA's own logo, standing in wherever a store has not uploaded one -
// My Store's header and the directory card. One definition, so the two
// never drift.
import 'package:flutter/material.dart';

class BrokaDefaultLogo extends StatelessWidget {
  const BrokaDefaultLogo({super.key});

  static const asset = 'assets/images/broka_icon.png';

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('store-default-logo'),
        color: Colors.white,
        child: Image.asset(asset, fit: BoxFit.cover),
      );
}
