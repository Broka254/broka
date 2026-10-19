// Stands in for the network layer under BrokaImage in widget tests.
//
// The real one (CachedNetworkImage) needs a network, a disk cache and
// plugins, none of which a widget test has. This swaps in a widget that
// answers from a set of URLs: a URL in [available] "loads" and shows a
// SizedBox keyed `loaded:<url>`; any other URL fails the way a download does
// - with a 404 unless [errors] says otherwise - by calling the errorWidget
// BrokaImage handed it. Every URL a widget starts loading goes into
// [requested], so a test can say which files were asked for, in what order,
// and how many times.
import 'dart:io' show HttpException;

import 'package:broka/widgets/broka_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Carries the HTTP status the way the cache manager's exception does.
class FakeHttpStatusException implements Exception {
  const FakeHttpStatusException(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'Invalid statusCode: $statusCode';
}

class FakeImageNetwork {
  FakeImageNetwork({Iterable<String> available = const [], Map<String, Object>? errors})
      : available = {...available},
        errors = {...?errors};

  /// URLs the "server" has. Every other URL answers 404.
  final Set<String> available;

  /// A different failure for a URL that isn't there (a dropped connection, a 410).
  final Map<String, Object> errors;

  /// Every URL a widget started loading, in order.
  final List<String> requested = [];

  NetworkImageBuilder? _original;

  Finder loaded(String url) => find.byKey(ValueKey('loaded:$url'));

  /// A plain 404 as an `HttpException` from dart:io, which carries its status
  /// only in its message.
  static HttpException notFoundMessageOnly(String url) =>
      HttpException('Invalid statusCode: 404, uri = $url');

  void install() {
    _original = BrokaImage.networkImageBuilder;
    BrokaImage.resetFailureMemory();
    BrokaImage.networkImageBuilder = ({
      required String url,
      required BoxFit fit,
      double? width,
      double? height,
      required Widget Function(BuildContext, String) placeholder,
      required Widget Function(BuildContext, String, Object) errorWidget,
    }) =>
        _FakeImage(network: this, url: url, errorWidget: errorWidget);
  }

  void uninstall() {
    final original = _original;
    if (original != null) BrokaImage.networkImageBuilder = original;
    BrokaImage.clock = DateTime.now;
    BrokaImage.resetFailureMemory();
  }
}

class _FakeImage extends StatefulWidget {
  const _FakeImage({required this.network, required this.url, required this.errorWidget});

  final FakeImageNetwork network;
  final String url;
  final Widget Function(BuildContext, String, Object) errorWidget;

  @override
  State<_FakeImage> createState() => _FakeImageState();
}

class _FakeImageState extends State<_FakeImage> {
  @override
  void initState() {
    super.initState();
    widget.network.requested.add(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final network = widget.network;
    if (network.available.contains(widget.url)) {
      return SizedBox.expand(key: ValueKey('loaded:${widget.url}'));
    }
    return widget.errorWidget(
      context,
      widget.url,
      network.errors[widget.url] ?? const FakeHttpStatusException(404),
    );
  }
}
