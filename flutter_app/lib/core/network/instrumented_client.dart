// The http.Client every BROKA request goes through: ApiClient's (by
// default) and ApiService's top-level http calls (main.dart runs the app
// inside http.runWithClient with this).
//
// Two jobs, neither of which touches the request or the bytes:
//  * NetworkStats: method, endpoint, status, size and time of each response;
//  * DataChanges: a successful change (POST/PATCH/DELETE 2xx) marks the
//    cached screens it affects out of date.
import 'dart:async';

import 'package:http/http.dart' as http;

import '../cache/data_changes.dart';
import 'network_stats.dart';

class InstrumentedClient extends http.BaseClient {
  InstrumentedClient(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final watch = Stopwatch()..start();
    late final http.StreamedResponse res;
    try {
      res = await _inner.send(request);
    } catch (_) {
      NetworkStats.instance.record(request.method, request.url,
          status: 0, bytes: 0, duration: watch.elapsed);
      rethrow;
    }
    // Never let bookkeeping break a request.
    try {
      DataChanges.instance.observeResponse(request.method, request.url, res.statusCode);
    } catch (_) {}
    var bytes = 0;
    var recorded = false;
    void done() {
      if (recorded) return;
      recorded = true;
      NetworkStats.instance.record(request.method, request.url,
          status: res.statusCode, bytes: bytes, duration: watch.elapsed);
    }

    final counted = res.stream.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        bytes += chunk.length;
        sink.add(chunk);
      },
      handleError: (error, stack, sink) {
        done();
        sink.addError(error, stack);
      },
      handleDone: (sink) {
        done();
        sink.close();
      },
    ));
    return http.StreamedResponse(
      http.ByteStream(counted),
      res.statusCode,
      contentLength: res.contentLength,
      request: res.request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
