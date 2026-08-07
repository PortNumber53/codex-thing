import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message, [this.statusCode]);

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class SseEvent {
  const SseEvent(this.name, this.data);

  final String name;
  final JsonMap data;
}

class CodexApi {
  CodexApi(String baseUrl, {http.Client? client})
    : baseUri = normalizeServerUri(baseUrl),
      _client = client ?? http.Client();

  final Uri baseUri;
  final http.Client _client;

  static Uri normalizeServerUri(String value) {
    var input = value.trim();
    while (input.endsWith('/')) {
      input = input.substring(0, input.length - 1);
    }
    final uri = Uri.tryParse(input);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException(
        'Use a complete http:// or https:// server address.',
      );
    }
    return uri;
  }

  Uri endpoint(String path, [Map<String, String>? query]) => baseUri.replace(
    path: '${baseUri.path.replaceFirst(RegExp(r'/$'), '')}$path',
    queryParameters: query,
  );

  Future<JsonMap> health() => _getJson(endpoint('/api/health'));

  Future<JsonMap> threads({String workspace = '', bool all = false}) =>
      _getJson(
        endpoint(
          '/api/threads',
          all
              ? {'scope': 'all'}
              : workspace.isEmpty
              ? null
              : {'cwd': workspace},
        ),
      );

  Future<JsonMap> thread(String threadId) =>
      _getJson(endpoint('/api/threads/${Uri.encodeComponent(threadId)}'));

  Future<AuthSnapshot> auth({bool start = false}) async {
    final uri = endpoint('/api/auth');
    final response = start ? await _client.post(uri) : await _client.get(uri);
    JsonMap body;
    try {
      body = _decodeMap(response.body);
    } catch (_) {
      body = <String, dynamic>{};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        jsonString(body['message']).isEmpty
            ? response.body.trim()
            : jsonString(body['message']),
        response.statusCode,
      );
    }
    return AuthSnapshot.fromJson(body);
  }

  Future<List<JsonMap>> completeWorkspace(String path) async {
    final data = await _getJson(
      endpoint('/api/workspaces/complete', {'path': path}),
    );
    return (data['suggestions'] as List? ?? const [])
        .map((item) => asJsonMap(item))
        .toList(growable: false);
  }

  Future<void> interrupt(String threadId, String turnId) async {
    final response = await _client.post(
      endpoint('/api/interrupt'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'threadId': threadId, 'turnId': turnId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.body.trim(), response.statusCode);
    }
  }

  Stream<SseEvent> chat({
    required String message,
    required String threadId,
    required String workspace,
  }) async* {
    final request = http.Request('POST', endpoint('/api/chat'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'message': message,
        'threadId': threadId,
        'workspace': workspace,
      });
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw ApiException(
        body.trim().isEmpty ? 'HTTP ${response.statusCode}' : body.trim(),
        response.statusCode,
      );
    }

    var eventName = 'message';
    final dataLines = <String>[];
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          yield SseEvent(eventName, _decodeMap(dataLines.join('\n')));
        }
        eventName = 'message';
        dataLines.clear();
      } else if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (dataLines.isNotEmpty) {
      yield SseEvent(eventName, _decodeMap(dataLines.join('\n')));
    }
  }

  WebSocketChannel openSocket() {
    final socketUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '${baseUri.path.replaceFirst(RegExp(r'/$'), '')}/api/ws',
      query: null,
    );
    return WebSocketChannel.connect(socketUri);
  }

  Future<JsonMap> _getJson(Uri uri) async {
    final response = await _client.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.body.trim().isEmpty
            ? 'HTTP ${response.statusCode}'
            : response.body.trim(),
        response.statusCode,
      );
    }
    return _decodeMap(response.body);
  }

  static JsonMap _decodeMap(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(body);
    return asJsonMap(decoded);
  }

  void close() => _client.close();
}
