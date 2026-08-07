import 'dart:convert';

typedef JsonMap = Map<String, dynamic>;

JsonMap asJsonMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

String jsonString(Object? value) => value is String ? value : '';

class AuthSnapshot {
  const AuthSnapshot({
    this.status = 'checking',
    this.requiresOpenAiAuth = true,
    this.authMode = '',
    this.planType = '',
    this.loginId = '',
    this.verificationUrl = '',
    this.userCode = '',
    this.message = '',
  });

  factory AuthSnapshot.fromJson(JsonMap json) => AuthSnapshot(
    status: jsonString(json['status']).isEmpty
        ? 'checking'
        : jsonString(json['status']),
    requiresOpenAiAuth: json['requiresOpenaiAuth'] != false,
    authMode: jsonString(json['authMode']),
    planType: jsonString(json['planType']),
    loginId: jsonString(json['loginId']),
    verificationUrl: jsonString(json['verificationUrl']),
    userCode: jsonString(json['userCode']),
    message: jsonString(json['message']),
  );

  final String status;
  final bool requiresOpenAiAuth;
  final String authMode;
  final String planType;
  final String loginId;
  final String verificationUrl;
  final String userCode;
  final String message;

  bool get authenticated => status == 'authenticated';
  bool get pending =>
      status == 'pending' && verificationUrl.isNotEmpty && userCode.isNotEmpty;
  bool get busy =>
      const {'checking', 'starting', 'syncing', 'completing'}.contains(status);
}

class ThreadSummary {
  const ThreadSummary({
    required this.id,
    required this.title,
    this.preview = '',
    this.cwd = '',
    this.updatedAt = 0,
    this.active = false,
  });

  factory ThreadSummary.fromJson(JsonMap json) {
    final status = asJsonMap(json['status']);
    return ThreadSummary(
      id: jsonString(json['id']),
      title: jsonString(json['title']).trim().isEmpty
          ? 'Untitled conversation'
          : jsonString(json['title']).trim(),
      preview: jsonString(json['preview']),
      cwd: jsonString(json['cwd']),
      updatedAt: json['updatedAt'] is num
          ? (json['updatedAt'] as num).toInt()
          : 0,
      active:
          jsonString(status['type']) == 'active' ||
          jsonString(json['status']) == 'active',
    );
  }

  final String id;
  final String title;
  final String preview;
  final String cwd;
  final int updatedAt;
  final bool active;
}

class ChatItem {
  const ChatItem({
    this.kind = '',
    this.id = '',
    this.role = '',
    this.text = '',
    this.command = '',
    this.cwd = '',
    this.output = '',
    this.status = '',
    this.exitCode,
    this.durationMs,
    this.liveItemId = '',
    this.error = false,
  });

  factory ChatItem.fromJson(JsonMap json) => ChatItem(
    kind: jsonString(json['kind']),
    id: jsonString(json['id']),
    role: jsonString(json['role']),
    text: jsonString(json['text']),
    command: jsonString(json['command']),
    cwd: jsonString(json['cwd']),
    output: jsonString(json['output']),
    status: jsonString(json['status']),
    exitCode: json['exitCode'] is num
        ? (json['exitCode'] as num).toInt()
        : null,
    durationMs: json['durationMs'] is num
        ? (json['durationMs'] as num).toInt()
        : null,
  );

  final String kind;
  final String id;
  final String role;
  final String text;
  final String command;
  final String cwd;
  final String output;
  final String status;
  final int? exitCode;
  final int? durationMs;
  final String liveItemId;
  final bool error;

  ChatItem copyWith({
    String? kind,
    String? id,
    String? role,
    String? text,
    String? command,
    String? cwd,
    String? output,
    String? status,
    int? exitCode,
    int? durationMs,
    String? liveItemId,
    bool? error,
  }) => ChatItem(
    kind: kind ?? this.kind,
    id: id ?? this.id,
    role: role ?? this.role,
    text: text ?? this.text,
    command: command ?? this.command,
    cwd: cwd ?? this.cwd,
    output: output ?? this.output,
    status: status ?? this.status,
    exitCode: exitCode ?? this.exitCode,
    durationMs: durationMs ?? this.durationMs,
    liveItemId: liveItemId ?? this.liveItemId,
    error: error ?? this.error,
  );
}

class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    this.kind = 'command',
    this.threadId = '',
    this.command = '',
    this.cwd = '',
    this.reason = '',
    this.environment = '',
    this.itemId = '',
    this.grantRoot = '',
    this.serverName = '',
    this.message = '',
    this.proposedExecPrefix = const [],
    this.permissions = const {},
    this.questions = const [],
  });

  factory ApprovalRequest.fromJson(JsonMap json) => ApprovalRequest(
    id: jsonString(json['id']),
    kind: jsonString(json['kind']).isEmpty
        ? 'command'
        : jsonString(json['kind']),
    threadId: jsonString(json['threadId']),
    command: jsonString(json['command']),
    cwd: jsonString(json['cwd']),
    reason: jsonString(json['reason']),
    environment: jsonString(json['environment']),
    itemId: jsonString(json['itemId']),
    grantRoot: jsonString(json['grantRoot']),
    serverName: jsonString(json['serverName']),
    message: jsonString(json['message']),
    proposedExecPrefix: (json['proposedExecPrefix'] as List? ?? const [])
        .map((item) => item.toString())
        .toList(growable: false),
    permissions: asJsonMap(json['permissions']),
    questions: (json['questions'] as List? ?? const [])
        .map((item) => ApprovalQuestion.fromJson(asJsonMap(item)))
        .toList(growable: false),
  );

  final String id;
  final String kind;
  final String threadId;
  final String command;
  final String cwd;
  final String reason;
  final String environment;
  final String itemId;
  final String grantRoot;
  final String serverName;
  final String message;
  final List<String> proposedExecPrefix;
  final JsonMap permissions;
  final List<ApprovalQuestion> questions;
}

class ApprovalQuestion {
  const ApprovalQuestion({
    required this.id,
    this.header = '',
    this.question = '',
    this.secret = false,
    this.options = const [],
  });

  factory ApprovalQuestion.fromJson(JsonMap json) => ApprovalQuestion(
    id: jsonString(json['id']),
    header: jsonString(json['header']),
    question: jsonString(json['question']),
    secret: json['isSecret'] == true,
    options: (json['options'] as List? ?? const [])
        .map((item) => ApprovalOption.fromJson(asJsonMap(item)))
        .toList(growable: false),
  );

  final String id;
  final String header;
  final String question;
  final bool secret;
  final List<ApprovalOption> options;
}

class ApprovalOption {
  const ApprovalOption({required this.label, this.description = ''});

  factory ApprovalOption.fromJson(JsonMap json) => ApprovalOption(
    label: jsonString(json['label']),
    description: jsonString(json['description']),
  );

  final String label;
  final String description;
}

class RuntimeSnapshot {
  const RuntimeSnapshot({
    this.threadId = '',
    this.turnId = '',
    this.working = false,
    this.activeFlags = const [],
    this.approvals = const [],
  });

  factory RuntimeSnapshot.fromJson(JsonMap json) => RuntimeSnapshot(
    threadId: jsonString(json['threadId']),
    turnId: jsonString(json['turnId']),
    working: json['working'] == true,
    activeFlags: (json['activeFlags'] as List? ?? const [])
        .map((item) => item.toString())
        .toList(growable: false),
    approvals: (json['approvals'] as List? ?? const [])
        .map((item) => ApprovalRequest.fromJson(asJsonMap(item)))
        .toList(growable: false),
  );

  final String threadId;
  final String turnId;
  final bool working;
  final List<String> activeFlags;
  final List<ApprovalRequest> approvals;
}

class MobileSession {
  MobileSession({
    required this.localId,
    this.threadId = '',
    this.title = 'New conversation',
    this.preview = '',
    this.workspace = '',
    this.updatedAt = 0,
    this.active = false,
    this.loaded = false,
    this.draft = false,
  });

  factory MobileSession.fromSummary(ThreadSummary summary) => MobileSession(
    localId: summary.id,
    threadId: summary.id,
    title: summary.title,
    preview: summary.preview,
    workspace: summary.cwd,
    updatedAt: summary.updatedAt,
    active: summary.active,
  );

  final String localId;
  String threadId;
  String title;
  String preview;
  String workspace;
  int updatedAt;
  bool active;
  bool loaded;
  bool loading = false;
  bool streaming = false;
  bool working = false;
  bool draft;
  String turnId = '';
  String activity = '';
  String error = '';
  String composerText = '';
  List<ChatItem> messages = [];
  List<ApprovalRequest> approvals = [];
  Set<String> decidingApprovals = {};

  void reconcileUserMessage({
    required String id,
    required String text,
    required bool claimOptimistic,
  }) {
    if (text.isEmpty) return;
    if (id.isNotEmpty && messages.any((message) => message.id == id)) return;

    if (claimOptimistic) {
      for (var index = messages.length - 1; index >= 0; index -= 1) {
        final message = messages[index];
        if (message.role == 'user' &&
            message.id.isEmpty &&
            message.text == text) {
          messages[index] = message.copyWith(id: id);
          return;
        }
      }
    }

    if (id.isEmpty) {
      final latestUser = messages.lastWhere(
        (message) => message.role == 'user',
        orElse: () => const ChatItem(),
      );
      if (latestUser.text == text) return;
    }
    messages.add(ChatItem(id: id, role: 'user', text: text));
  }

  void updateSummary(ThreadSummary summary) {
    title = summary.title;
    preview = summary.preview;
    workspace = summary.cwd;
    updatedAt = summary.updatedAt;
    active = summary.active || working;
  }

  void applyRuntime(RuntimeSnapshot runtime) {
    working = runtime.working;
    active = runtime.working;
    turnId = runtime.turnId;
    approvals = runtime.approvals;
    decidingApprovals.removeWhere(
      (id) => !approvals.any((approval) => approval.id == id),
    );
    if (!working) {
      activity = '';
    } else if (approvals.isNotEmpty ||
        runtime.activeFlags.contains('waitingOnApproval')) {
      activity = 'Waiting for approval';
    } else if (activity.isEmpty) {
      activity = 'Working';
    }
  }
}

String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
