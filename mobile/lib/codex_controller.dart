import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'codex_api.dart';
import 'models.dart';

enum BridgeConnection { connecting, ready, offline }

class CodexController extends ChangeNotifier {
  CodexController({String? initialServerUrl, bool preview = false})
    : _serverUrl = initialServerUrl ?? _defaultServerUrl,
      _preview = preview {
    _api = CodexApi(_serverUrl);
    if (preview) {
      connection = BridgeConnection.ready;
      auth = const AuthSnapshot(status: 'authenticated', authMode: 'chatgpt');
      defaultWorkspace = '/workspace/androidex';
      sessions.add(
        MobileSession(
            localId: 'preview',
            threadId: 'preview',
            title: 'Build the mobile client',
            workspace: defaultWorkspace,
            loaded: true,
            active: true,
          )
          ..messages = const [
            ChatItem(
              role: 'user',
              text: 'Create a mobile experience for Codex.',
            ),
            ChatItem(
              role: 'assistant',
              text:
                  'The mobile client is connected. Swipe horizontally to move between sessions.',
            ),
          ],
      );
      sessions.add(
        MobileSession(
            localId: 'preview-2',
            threadId: 'preview-2',
            title: 'Review backend changes',
            workspace: defaultWorkspace,
            loaded: true,
          )
          ..messages = const [
            ChatItem(
              role: 'assistant',
              text:
                  'This is a second session. Swipe back to continue the first.',
            ),
          ],
      );
    }
  }

  static const String _defaultServerUrl = String.fromEnvironment(
    'CODEX_SERVER_URL',
    defaultValue: 'http://10.0.2.2:40001',
  );
  static const String _serverPreference = 'codex_server_url';

  late CodexApi _api;
  final bool _preview;
  SharedPreferences? _preferences;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _reconnectTimer;
  Timer? _healthTimer;
  bool _connectingSocket = false;
  bool _disposed = false;
  int _draftSequence = 0;
  String _serverUrl;

  BridgeConnection connection = BridgeConnection.connecting;
  AuthSnapshot auth = const AuthSnapshot();
  String defaultWorkspace = '';
  String connectionError = '';
  bool socketConnected = false;
  int selectedIndex = 0;
  final List<MobileSession> sessions = [];

  String get serverUrl => _serverUrl;
  MobileSession? get selectedSession => sessions.isEmpty
      ? null
      : sessions[selectedIndex.clamp(0, sessions.length - 1)];

  Future<void> initialize() async {
    if (_preview) return;
    _preferences = await SharedPreferences.getInstance();
    final saved = _preferences?.getString(_serverPreference)?.trim();
    if (saved != null && saved.isNotEmpty && saved != _serverUrl) {
      _api.close();
      _serverUrl = saved;
      _api = CodexApi(_serverUrl);
    }
    await reconnect();
    _healthTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => refreshHealth(silent: true),
    );
  }

  Future<void> reconnect() async {
    connection = BridgeConnection.connecting;
    connectionError = '';
    _notify();
    try {
      await refreshHealth();
      await refreshThreads();
      await _connectSocket();
      final session = selectedSession;
      if (session != null) {
        await selectSession(selectedIndex);
      }
    } catch (error) {
      connection = BridgeConnection.offline;
      connectionError = error.toString();
      _notify();
    }
  }

  Future<void> refreshHealth({bool silent = false}) async {
    try {
      final data = await _api.health();
      connection = jsonString(data['codex']) == 'ready'
          ? BridgeConnection.ready
          : BridgeConnection.offline;
      defaultWorkspace = jsonString(data['workspace']);
      final authJson = asJsonMap(data['auth']);
      auth = authJson.isEmpty
          ? const AuthSnapshot(
              status: 'authenticated',
              requiresOpenAiAuth: false,
            )
          : AuthSnapshot.fromJson(authJson);
      connectionError = connection == BridgeConnection.ready
          ? ''
          : 'Codex app-server is unavailable.';
      _notify();
    } catch (error) {
      connection = BridgeConnection.offline;
      if (!silent || connectionError.isEmpty) {
        connectionError = error.toString();
      }
      _notify();
      if (!silent) rethrow;
    }
  }

  Future<void> refreshThreads() async {
    if (connection != BridgeConnection.ready) return;
    try {
      final data = await _api.threads(all: true);
      if (defaultWorkspace.isEmpty) {
        defaultWorkspace = jsonString(data['workspace']);
      }
      final summaries = (data['threads'] as List? ?? const [])
          .map((item) => ThreadSummary.fromJson(asJsonMap(item)))
          .where((item) => item.id.isNotEmpty)
          .toList();
      summaries.sort((left, right) {
        if (left.active != right.active) return left.active ? -1 : 1;
        return right.updatedAt.compareTo(left.updatedAt);
      });

      final returnedIds = summaries.map((item) => item.id).toSet();
      for (final summary in summaries) {
        final existing = sessions
            .where((session) => session.threadId == summary.id)
            .firstOrNull;
        if (existing != null) {
          existing.updateSummary(summary);
        } else {
          sessions.add(MobileSession.fromSummary(summary));
        }
      }
      sessions.removeWhere(
        (session) =>
            !session.draft &&
            !session.working &&
            session.threadId.isNotEmpty &&
            !returnedIds.contains(session.threadId),
      );
      if (sessions.isEmpty) {
        _addDraft(defaultWorkspace, notify: false);
      }
      selectedIndex = selectedIndex.clamp(0, sessions.length - 1);
      _notify();
    } catch (error) {
      connectionError = 'Could not load sessions: $error';
      _notify();
    }
  }

  Future<void> selectSession(int index) async {
    if (sessions.isEmpty) return;
    selectedIndex = index.clamp(0, sessions.length - 1);
    final session = sessions[selectedIndex];
    _notify();
    await openSession(session);
  }

  Future<void> openSession(MobileSession session) async {
    if (session.threadId.isNotEmpty) {
      subscribe(session.threadId);
      await loadSession(session);
    } else {
      session.loaded = true;
      _notify();
    }
  }

  Future<void> renameSession(MobileSession session, String rawName) async {
    final name = rawName.trim();
    if (session.threadId.isEmpty || session.draft) {
      throw const ApiException('Start the conversation before renaming it.');
    }
    if (name.isEmpty) {
      throw const ApiException('Enter a session name.');
    }
    if (name.runes.length > 200) {
      throw const ApiException(
        'Session names can contain up to 200 characters.',
      );
    }

    final previousTitle = session.title;
    session.title = name;
    _notify();
    if (_preview) return;

    try {
      final data = await _api.renameThread(session.threadId, name);
      final title = jsonString(data['title']).trim();
      if (title.isNotEmpty) session.title = title;
      _notify();
    } catch (error) {
      session.title = previousTitle;
      _notify();
      rethrow;
    }
  }

  MobileSession createDraft(String workspace, {bool select = true}) {
    final draft = _addDraft(
      workspace.trim().isEmpty ? defaultWorkspace : workspace.trim(),
      notify: false,
    );
    if (select) selectedIndex = sessions.indexOf(draft);
    _notify();
    return draft;
  }

  MobileSession _addDraft(String workspace, {required bool notify}) {
    final draft = MobileSession(
      localId:
          'draft-${DateTime.now().microsecondsSinceEpoch}-${_draftSequence++}',
      workspace: workspace,
      loaded: true,
      draft: true,
    );
    sessions.add(draft);
    if (notify) _notify();
    return draft;
  }

  Future<void> loadSession(MobileSession session, {bool force = false}) async {
    if (session.threadId.isEmpty || session.loading) return;
    if (session.loaded && !force) return;
    session.loading = true;
    session.error = '';
    _notify();
    try {
      final data = await _api.thread(session.threadId);
      session.threadId = jsonString(data['threadId']).isEmpty
          ? session.threadId
          : jsonString(data['threadId']);
      final title = jsonString(data['title']).trim();
      if (title.isNotEmpty) session.title = title;
      final workspace = jsonString(data['workspace']);
      if (workspace.isNotEmpty) session.workspace = workspace;
      session.messages = (data['messages'] as List? ?? const [])
          .map((item) => ChatItem.fromJson(asJsonMap(item)))
          .toList();
      session.applyRuntime(
        RuntimeSnapshot.fromJson(asJsonMap(data['runtime'])),
      );
      session.loaded = true;
    } catch (error) {
      session.error = "I couldn't load this session: $error";
    } finally {
      session.loading = false;
      _notify();
    }
  }

  Future<void> sendMessage(MobileSession session, String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || session.working || !auth.authenticated) return;
    if (session.threadId.isEmpty &&
        (!session.workspace.startsWith('/') || session.workspace.isEmpty)) {
      session.error = 'Choose an absolute workspace path before sending.';
      _notify();
      return;
    }

    session.error = '';
    session.streaming = true;
    session.working = true;
    session.active = true;
    session.activity = 'Thinking';
    session.composerText = '';
    session.messages.add(ChatItem(role: 'user', text: message));
    session.messages.add(const ChatItem(role: 'assistant'));
    _notify();

    try {
      await for (final event in _api.chat(
        message: message,
        threadId: session.threadId,
        workspace: session.threadId.isEmpty ? session.workspace : '',
      )) {
        switch (event.name) {
          case 'ready':
            final threadId = jsonString(event.data['threadId']);
            if (threadId.isNotEmpty) {
              session.threadId = threadId;
              session.draft = false;
              session.turnId = jsonString(event.data['turnId']);
              final workspace = jsonString(event.data['workspace']);
              if (workspace.isNotEmpty) session.workspace = workspace;
              subscribe(threadId);
            }
          case 'delta':
            session.activity = '';
            _appendAssistantDelta(
              session,
              jsonString(event.data['text']),
              jsonString(event.data['itemId']),
            );
          case 'activity':
            session.activity = jsonString(event.data['label']);
          case 'protocol':
            _handleRealtime(event.data, allowStreaming: true);
          case 'error':
            throw ApiException(
              jsonString(event.data['message']).isEmpty
                  ? 'The turn failed.'
                  : jsonString(event.data['message']),
            );
        }
        _notify();
      }
    } catch (error) {
      final text = "I couldn't complete that turn: $error";
      if (session.messages.isNotEmpty &&
          session.messages.last.role == 'assistant' &&
          session.messages.last.text.isEmpty) {
        session.messages[session.messages.length - 1] = ChatItem(
          role: 'assistant',
          text: text,
          error: true,
        );
      } else {
        session.messages.add(
          ChatItem(role: 'assistant', text: text, error: true),
        );
      }
    } finally {
      session.streaming = false;
      session.working = false;
      session.active = false;
      session.activity = '';
      session.turnId = '';
      _notify();
      if (session.threadId.isNotEmpty) {
        await loadSession(session, force: true);
      }
      await refreshThreads();
    }
  }

  Future<void> interrupt(MobileSession session) async {
    if (session.threadId.isEmpty || !session.working) return;
    try {
      await _api.interrupt(session.threadId, session.turnId);
    } catch (error) {
      session.error = 'Could not interrupt this turn: $error';
      _notify();
    }
  }

  Future<void> requestDeviceLogin() async {
    auth = const AuthSnapshot(
      status: 'starting',
      message: 'Requesting a one-time OpenAI sign-in code…',
    );
    _notify();
    try {
      auth = await _api.auth(start: true);
    } catch (error) {
      auth = AuthSnapshot(
        status: 'error',
        message: 'Could not start sign-in: $error',
      );
    }
    _notify();
  }

  Future<List<JsonMap>> completeWorkspace(String path) =>
      _api.completeWorkspace(path);

  Future<void> decideApproval(
    MobileSession session,
    ApprovalRequest approval,
    String decision, {
    Map<String, List<String>>? answers,
    JsonMap? content,
  }) async {
    if (!socketConnected || _socket == null) {
      session.error = 'The realtime connection is not ready.';
      _notify();
      return;
    }
    session.decidingApprovals.add(approval.id);
    session.error = '';
    _notify();
    _socket!.sink.add(
      jsonEncode({
        'type': 'approval/decide',
        'approvalId': approval.id,
        'decision': decision,
        'answers': ?answers,
        'content': ?content,
      }),
    );
  }

  Future<void> updateServerUrl(String value) async {
    final uri = CodexApi.normalizeServerUri(value);
    final normalized = uri.toString().replaceFirst(RegExp(r'/$'), '');
    await _closeSocket();
    _api.close();
    _serverUrl = normalized;
    _api = CodexApi(normalized);
    await _preferences?.setString(_serverPreference, normalized);
    sessions.clear();
    selectedIndex = 0;
    auth = const AuthSnapshot();
    await reconnect();
  }

  Future<void> _connectSocket() async {
    if (_connectingSocket || socketConnected || _disposed) return;
    _connectingSocket = true;
    _reconnectTimer?.cancel();
    try {
      final socket = _api.openSocket();
      await socket.ready;
      if (_disposed) {
        await socket.sink.close();
        return;
      }
      _socket = socket;
      socketConnected = true;
      _socketSubscription = socket.stream.listen(
        (payload) {
          try {
            _handleRealtime(asJsonMap(jsonDecode(payload.toString())));
          } catch (_) {
            // Ignore malformed protocol messages and retain the connection.
          }
        },
        onError: (_) => _socketClosed(),
        onDone: _socketClosed,
        cancelOnError: true,
      );
      final session = selectedSession;
      if (session?.threadId.isNotEmpty == true) {
        subscribe(session!.threadId);
      }
      _notify();
    } catch (error) {
      socketConnected = false;
      connectionError = 'Realtime connection failed: $error';
      _scheduleReconnect();
      _notify();
    } finally {
      _connectingSocket = false;
    }
  }

  void _socketClosed() {
    socketConnected = false;
    _socket = null;
    _socketSubscription = null;
    _scheduleReconnect();
    _notify();
  }

  void _scheduleReconnect() {
    if (_disposed || _preview) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 1), _connectSocket);
  }

  void subscribe(String threadId) {
    if (!socketConnected || threadId.isEmpty) return;
    _socket?.sink.add(jsonEncode({'type': 'subscribe', 'threadId': threadId}));
  }

  void _handleRealtime(JsonMap event, {bool allowStreaming = false}) {
    final type = jsonString(event['type']);
    if (type == 'auth/snapshot') {
      auth = AuthSnapshot.fromJson(event);
      _notify();
      return;
    }
    if (type == 'runtime/snapshot') {
      final runtime = RuntimeSnapshot.fromJson(event);
      final session = _sessionByThread(runtime.threadId);
      session?.applyRuntime(runtime);
      _notify();
      return;
    }
    if (type == 'approval/resolved') {
      final session = _sessionByThread(jsonString(event['threadId']));
      final approvalId = jsonString(event['approvalId']);
      if (session != null) {
        session.approvals.removeWhere((item) => item.id == approvalId);
        session.decidingApprovals.remove(approvalId);
      }
      _notify();
      return;
    }
    if (type == 'approval/submitted') {
      final session = _sessionByThread(jsonString(event['threadId']));
      session?.decidingApprovals.add(jsonString(event['approvalId']));
      _notify();
      return;
    }
    if (type == 'approval/error') {
      final approvalId = jsonString(event['approvalId']);
      for (final session in sessions) {
        if (session.decidingApprovals.remove(approvalId)) {
          session.error = jsonString(event['message']);
        }
      }
      _notify();
      return;
    }
    if (type == 'subscriptionError') {
      final session = _sessionByThread(jsonString(event['threadId']));
      if (session != null) session.error = jsonString(event['message']);
      _notify();
      return;
    }
    if (type != 'notification') return;

    final method = jsonString(event['method']);
    final params = asJsonMap(event['params']);
    if (const {
      'thread/started',
      'thread/name/updated',
      'thread/archived',
      'thread/unarchived',
      'thread/deleted',
    }.contains(method)) {
      unawaited(refreshThreads());
    }
    final session = _sessionByThread(jsonString(params['threadId']));
    if (session == null || (session.streaming && !allowStreaming)) return;

    final item = asJsonMap(params['item']);
    switch (method) {
      case 'turn/started':
        session.working = true;
        session.active = true;
        session.turnId = jsonString(asJsonMap(params['turn'])['id']);
        session.activity = 'Working';
      case 'item/started' when jsonString(item['type']) == 'userMessage':
        final text = (item['content'] as List? ?? const [])
            .map(asJsonMap)
            .where((part) => jsonString(part['type']) == 'text')
            .map((part) => jsonString(part['text']))
            .where((text) => text.trim().isNotEmpty)
            .join('\n')
            .trim();
        if (text.isNotEmpty &&
            (session.messages.isEmpty ||
                session.messages.last.role != 'user' ||
                session.messages.last.text != text)) {
          session.messages.add(ChatItem(role: 'user', text: text));
        }
      case 'item/agentMessage/delta':
        session.activity = '';
        _appendAssistantDelta(
          session,
          jsonString(params['delta']),
          jsonString(params['itemId']),
        );
      case 'item/commandExecution/outputDelta':
        _upsertCommand(
          session,
          id: jsonString(params['itemId']),
          status: 'inProgress',
          outputDelta: jsonString(params['delta']),
        );
      case 'item/started' || 'item/completed'
          when jsonString(item['type']) == 'commandExecution':
        session.activity = method == 'item/started'
            ? 'Running ${jsonString(item['command']).isEmpty ? 'a command' : jsonString(item['command'])}'
            : '';
        _upsertCommand(
          session,
          id: jsonString(item['id']),
          command: jsonString(item['command']),
          cwd: jsonString(item['cwd']),
          output: jsonString(item['aggregatedOutput']),
          status: jsonString(item['status']),
          exitCode: item['exitCode'] is num
              ? (item['exitCode'] as num).toInt()
              : null,
          durationMs: item['durationMs'] is num
              ? (item['durationMs'] as num).toInt()
              : null,
        );
      case 'item/started':
        session.activity = switch (jsonString(item['type'])) {
          'fileChange' => 'Updating workspace files',
          'webSearch' =>
            'Searching for ${jsonString(item['query']).isEmpty ? 'information' : jsonString(item['query'])}',
          'reasoning' => 'Working through the request',
          _ => session.activity,
        };
      case 'item/completed' when jsonString(item['type']) == 'agentMessage':
        final index = session.messages.indexWhere(
          (message) => message.liveItemId == jsonString(item['id']),
        );
        if (index >= 0) {
          session.messages[index] = ChatItem(
            role: 'assistant',
            text: jsonString(item['text']),
            id: jsonString(item['id']),
          );
        }
      case 'turn/completed':
        session.working = false;
        session.active = false;
        session.turnId = '';
        session.approvals = [];
        session.activity = '';
        final turn = asJsonMap(params['turn']);
        if (jsonString(turn['status']) == 'interrupted' &&
            !session.messages.any(
              (message) =>
                  message.kind == 'notice' &&
                  message.id == jsonString(turn['id']),
            )) {
          session.messages.add(
            ChatItem(
              kind: 'notice',
              id: jsonString(turn['id']),
              status: 'interrupted',
              text:
                  'Conversation interrupted — tell the model what to do differently.',
            ),
          );
        }
        if (!session.streaming) {
          unawaited(loadSession(session, force: true));
        }
        unawaited(refreshThreads());
    }
    _notify();
  }

  void _appendAssistantDelta(
    MobileSession session,
    String delta,
    String itemId,
  ) {
    if (delta.isEmpty) return;
    var index = itemId.isEmpty
        ? -1
        : session.messages.indexWhere(
            (message) => message.liveItemId == itemId,
          );
    if (index < 0 &&
        session.messages.isNotEmpty &&
        session.messages.last.role == 'assistant' &&
        session.messages.last.text.isEmpty) {
      index = session.messages.length - 1;
    }
    if (index < 0) {
      session.messages.add(
        ChatItem(role: 'assistant', text: delta, liveItemId: itemId),
      );
      return;
    }
    final current = session.messages[index];
    session.messages[index] = current.copyWith(
      text: '${current.text}$delta',
      liveItemId: itemId.isEmpty ? current.liveItemId : itemId,
    );
  }

  void _upsertCommand(
    MobileSession session, {
    required String id,
    String? command,
    String? cwd,
    String? output,
    String outputDelta = '',
    String? status,
    int? exitCode,
    int? durationMs,
  }) {
    if (session.messages.isNotEmpty &&
        session.messages.last.role == 'assistant' &&
        session.messages.last.text.isEmpty) {
      session.messages.removeLast();
    }
    final index = session.messages.indexWhere(
      (message) => message.kind == 'command' && message.id == id,
    );
    if (index < 0) {
      session.messages.add(
        ChatItem(
          kind: 'command',
          id: id,
          command: command ?? '',
          cwd: cwd ?? '',
          output: '${output ?? ''}$outputDelta',
          status: status ?? '',
          exitCode: exitCode,
          durationMs: durationMs,
        ),
      );
      return;
    }
    final current = session.messages[index];
    session.messages[index] = current.copyWith(
      command: command,
      cwd: cwd,
      output: output ?? '${current.output}$outputDelta',
      status: status,
      exitCode: exitCode,
      durationMs: durationMs,
    );
  }

  MobileSession? _sessionByThread(String threadId) {
    if (threadId.isEmpty) return null;
    for (final session in sessions) {
      if (session.threadId == threadId) return session;
    }
    return null;
  }

  Future<void> _closeSocket() async {
    _reconnectTimer?.cancel();
    await _socketSubscription?.cancel();
    await _socket?.sink.close();
    _socket = null;
    _socketSubscription = null;
    socketConnected = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    unawaited(_socketSubscription?.cancel());
    unawaited(_socket?.sink.close());
    _api.close();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
