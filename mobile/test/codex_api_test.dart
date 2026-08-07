import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/codex_api.dart';

void main() {
  test('normalizes supported bridge URLs', () {
    expect(
      CodexApi.normalizeServerUri('http://10.0.2.2:40001/').toString(),
      'http://10.0.2.2:40001',
    );
    expect(
      () => CodexApi.normalizeServerUri('10.0.2.2:40001'),
      throwsFormatException,
    );
  });

  test('parses the Go bridge SSE event stream', () async {
    const body =
        'event: ready\n'
        'data: {"threadId":"thread-1","turnId":"turn-1"}\n'
        '\n'
        'event: delta\n'
        'data: {"text":"Hello","itemId":"item-1"}\n'
        '\n'
        'event: done\n'
        'data: {"status":"completed"}\n'
        '\n';
    final api = CodexApi('http://codex.test:40001', client: _FakeClient(body));
    addTearDown(api.close);

    final events = await api
        .chat(message: 'Hi', threadId: '', workspace: '/workspace')
        .toList();

    expect(events.map((event) => event.name), ['ready', 'delta', 'done']);
    expect(events[0].data['threadId'], 'thread-1');
    expect(events[1].data['text'], 'Hello');
  });
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.method, 'POST');
    expect(request.url.path, '/api/chat');
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: const {'content-type': 'text/event-stream'},
    );
  }
}
