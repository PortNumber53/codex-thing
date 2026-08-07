import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'codex_controller.dart';
import 'models.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0E1014),
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );
  runApp(const CodexMobileApp());
}

class CodexMobileApp extends StatefulWidget {
  const CodexMobileApp({super.key, this.controller});

  final CodexController? controller;

  @override
  State<CodexMobileApp> createState() => _CodexMobileAppState();
}

class _CodexMobileAppState extends State<CodexMobileApp> {
  late final CodexController controller;
  late final bool ownsController;

  @override
  void initState() {
    super.initState();
    ownsController = widget.controller == null;
    controller = widget.controller ?? CodexController();
    if (ownsController) unawaited(controller.initialize());
  }

  @override
  void dispose() {
    if (ownsController) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF0E1014);
    const surface = Color(0xFF171A20);
    const accent = Color(0xFFB7F7D2);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: surface,
    );
    return MaterialApp(
      title: 'Codex Local',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        canvasColor: background,
        fontFamily: 'Roboto',
        dividerColor: const Color(0xFF2A2E37),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF20242C),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF303640)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: accent, width: 1.2),
          ),
        ),
      ),
      home: CodexHome(controller: controller),
    );
  }
}

class CodexHome extends StatefulWidget {
  const CodexHome({super.key, required this.controller});

  final CodexController controller;

  @override
  State<CodexHome> createState() => _CodexHomeState();
}

class _CodexHomeState extends State<CodexHome> {
  late final PageController _pages;
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  String _composerSessionId = '';

  @override
  void initState() {
    super.initState();
    _pages = PageController(initialPage: widget.controller.selectedIndex);
    widget.controller.addListener(_controllerChanged);
    _syncComposer();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _pages.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _controllerChanged() {
    if (!mounted) return;
    _syncComposer();
    if (_pages.hasClients) {
      final page = _pages.page;
      if (page != null &&
          (page - page.round()).abs() < .001 &&
          page.round() != widget.controller.selectedIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pages.hasClients) {
            _pages.jumpToPage(widget.controller.selectedIndex);
          }
        });
      }
    }
  }

  void _syncComposer() {
    final session = widget.controller.selectedSession;
    if (session == null || session.localId == _composerSessionId) return;
    _composerSessionId = session.localId;
    _composer.value = TextEditingValue(
      text: session.composerText,
      selection: TextSelection.collapsed(offset: session.composerText.length),
    );
  }

  Future<void> _selectPage(int index) async {
    final oldSession = widget.controller.selectedSession;
    if (oldSession != null) oldSession.composerText = _composer.text;
    await widget.controller.selectSession(index);
    _syncComposer();
  }

  Future<void> _newConversation() async {
    final workspace = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171A20),
      builder: (context) => WorkspacePickerSheet(
        controller: widget.controller,
        initialPath: widget.controller.defaultWorkspace,
      ),
    );
    if (!mounted || workspace == null) return;
    final draft = widget.controller.createDraft(workspace);
    _composerSessionId = draft.localId;
    _composer.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pages.hasClients) {
        _pages.animateToPage(
          widget.controller.selectedIndex,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      _composerFocus.requestFocus();
    });
  }

  Future<void> _showSessions() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF171A20),
      builder: (context) => SessionPickerSheet(
        sessions: widget.controller.sessions,
        selectedIndex: widget.controller.selectedIndex,
        onRename: widget.controller.renameSession,
        onReorder: widget.controller.reorderSessions,
        onNew: () {
          Navigator.pop(context);
          unawaited(_newConversation());
        },
      ),
    );
    if (selected == null || !mounted) return;
    await _selectPage(selected);
    if (_pages.hasClients) {
      await _pages.animateToPage(
        selected,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _showSettings() async {
    final changed = await showDialog<String>(
      context: context,
      builder: (context) =>
          ServerSettingsDialog(initialUrl: widget.controller.serverUrl),
    );
    if (changed == null || !mounted) return;
    try {
      await widget.controller.updateServerUrl(changed);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Codex server updated.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _send() async {
    final session = widget.controller.selectedSession;
    final text = _composer.text.trim();
    if (session == null || text.isEmpty) return;
    _composer.clear();
    session.composerText = '';
    await widget.controller.sendMessage(session, text);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final session = controller.selectedSession;
      final authBlocked =
          controller.connection == BridgeConnection.ready &&
          !controller.auth.authenticated;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      final displaySize = MediaQuery.sizeOf(context);
      final dualPane =
          displaySize.width >= 900 && displaySize.width > displaySize.height;
      if (dualPane) {
        final sessionCount = controller.sessions.length;
        final primaryIndex = sessionCount == 0
            ? 0
            : controller.selectedIndex.clamp(0, sessionCount - 1);
        final secondaryIndex = sessionCount < 2
            ? primaryIndex
            : (primaryIndex + 1) % sessionCount;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            bottom: false,
            child: Row(
              children: [
                Expanded(
                  child: _LandscapeConversationPane(
                    key: const ValueKey('landscape-primary'),
                    controller: controller,
                    initialIndex: primaryIndex,
                    primary: true,
                    onSettings: _showSettings,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: _LandscapeConversationPane(
                    key: const ValueKey('landscape-secondary'),
                    controller: controller,
                    initialIndex: secondaryIndex,
                    primary: false,
                    onSettings: _showSettings,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              PersistentActionBar(
                connection: controller.connection,
                session: session,
                socketConnected: controller.socketConnected,
                authBlocked: authBlocked,
                hasSessions: controller.sessions.isNotEmpty,
                onSessions: _showSessions,
                onNew: _newConversation,
                onSettings: _showSettings,
              ),
              Expanded(
                child: switch (controller.connection) {
                  BridgeConnection.connecting => const ConnectionStateView(
                    title: 'Connecting to Codex…',
                    message: 'Looking for the shared app-server bridge.',
                    loading: true,
                  ),
                  BridgeConnection.offline => ConnectionStateView(
                    title: 'Codex is offline',
                    message: controller.connectionError.isEmpty
                        ? 'The mobile app could not reach the Go bridge.'
                        : controller.connectionError,
                    onRetry: controller.reconnect,
                  ),
                  BridgeConnection.ready when authBlocked => AuthView(
                    auth: controller.auth,
                    onRetry: controller.requestDeviceLogin,
                  ),
                  BridgeConnection.ready =>
                    controller.sessions.isEmpty
                        ? ConnectionStateView(
                            title: 'No conversations yet',
                            message: 'Start a conversation in any workspace.',
                            onRetry: _newConversation,
                            retryLabel: 'New conversation',
                          )
                        : PageView.builder(
                            controller: _pages,
                            physics: const PageScrollPhysics(),
                            onPageChanged: _selectPage,
                            itemCount: controller.sessions.length,
                            findChildIndexCallback: (key) {
                              if (key is! ValueKey<String>) return null;
                              final index = controller.sessions.indexWhere(
                                (session) => session.localId == key.value,
                              );
                              return index < 0 ? null : index;
                            },
                            itemBuilder: (context, index) => SessionPage(
                              key: ValueKey(controller.sessions[index].localId),
                              session: controller.sessions[index],
                              onPrompt: (prompt) {
                                _composer.text = prompt;
                                _send();
                              },
                              onApproval: controller.decideApproval,
                            ),
                          ),
                },
              ),
            ],
          ),
        ),
        bottomNavigationBar: AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: ComposerBar(
            controller: _composer,
            focusNode: _composerFocus,
            session: session,
            sessionIndex: controller.selectedIndex,
            sessionCount: controller.sessions.length,
            enabled:
                controller.connection == BridgeConnection.ready &&
                controller.auth.authenticated,
            onChanged: (value) {
              final current = controller.selectedSession;
              if (current != null) current.composerText = value;
            },
            onSend: _send,
            onStop: session == null
                ? null
                : () => controller.interrupt(session),
          ),
        ),
      );
    },
  );
}

class _LandscapeConversationPane extends StatefulWidget {
  const _LandscapeConversationPane({
    super.key,
    required this.controller,
    required this.initialIndex,
    required this.primary,
    required this.onSettings,
  });

  final CodexController controller;
  final int initialIndex;
  final bool primary;
  final VoidCallback onSettings;

  @override
  State<_LandscapeConversationPane> createState() =>
      _LandscapeConversationPaneState();
}

class _LandscapeConversationPaneState
    extends State<_LandscapeConversationPane> {
  late final PageController _pages;
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  late int _selectedIndex;
  late bool _hadSessions;
  String _selectedSessionId = '';
  String _composerSessionId = '';

  MobileSession? get _session {
    if (widget.controller.sessions.isEmpty) return null;
    return widget.controller.sessions[_selectedIndex.clamp(
      0,
      widget.controller.sessions.length - 1,
    )];
  }

  @override
  void initState() {
    super.initState();
    _hadSessions = widget.controller.sessions.isNotEmpty;
    _selectedIndex = _normalizedIndex(widget.initialIndex);
    _selectedSessionId = _session?.localId ?? '';
    _pages = PageController(initialPage: _selectedIndex);
    _syncComposer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = _session;
      if (session != null) unawaited(widget.controller.openSession(session));
    });
  }

  @override
  void didUpdateWidget(covariant _LandscapeConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasSessions = widget.controller.sessions.isNotEmpty;
    final rememberedIndex = _selectedSessionId.isEmpty
        ? -1
        : widget.controller.sessions.indexWhere(
            (session) => session.localId == _selectedSessionId,
          );
    final normalized = _normalizedIndex(
      !_hadSessions && hasSessions
          ? widget.initialIndex
          : rememberedIndex >= 0
          ? rememberedIndex
          : _selectedIndex,
    );
    _hadSessions = hasSessions;
    if (normalized != _selectedIndex) {
      _selectedIndex = normalized;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pages.hasClients) _pages.jumpToPage(_selectedIndex);
      });
    }
    _syncComposer();
    final session = _session;
    _selectedSessionId = session?.localId ?? '';
    if (session != null && !session.loaded && !session.loading) {
      unawaited(widget.controller.openSession(session));
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  int _normalizedIndex(int index) {
    final count = widget.controller.sessions.length;
    return count == 0 ? 0 : index.clamp(0, count - 1);
  }

  void _syncComposer() {
    final session = _session;
    if (session == null || session.localId == _composerSessionId) return;
    _composerSessionId = session.localId;
    _composer.value = TextEditingValue(
      text: session.composerText,
      selection: TextSelection.collapsed(offset: session.composerText.length),
    );
  }

  Future<void> _selectPage(int index) async {
    final oldSession = _session;
    if (oldSession != null) oldSession.composerText = _composer.text;
    if (mounted) setState(() => _selectedIndex = _normalizedIndex(index));
    _syncComposer();
    final session = _session;
    if (session == null) return;
    _selectedSessionId = session.localId;
    if (widget.primary) {
      await widget.controller.selectSession(_selectedIndex);
    } else {
      await widget.controller.openSession(session);
    }
  }

  Future<void> _newConversation() async {
    final workspace = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171A20),
      builder: (context) => WorkspacePickerSheet(
        controller: widget.controller,
        initialPath: widget.controller.defaultWorkspace,
      ),
    );
    if (!mounted || workspace == null) return;
    final draft = widget.controller.createDraft(
      workspace,
      select: widget.primary,
    );
    _selectedIndex = widget.controller.sessions.indexOf(draft);
    _selectedSessionId = draft.localId;
    _composerSessionId = draft.localId;
    _composer.clear();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pages.hasClients) {
        _pages.animateToPage(
          _selectedIndex,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      _composerFocus.requestFocus();
    });
  }

  Future<void> _showSessions() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF171A20),
      builder: (context) => SessionPickerSheet(
        sessions: widget.controller.sessions,
        selectedIndex: _selectedIndex,
        onRename: widget.controller.renameSession,
        onReorder: widget.controller.reorderSessions,
        onNew: () {
          Navigator.pop(context);
          unawaited(_newConversation());
        },
      ),
    );
    if (selected == null || !mounted) return;
    await _selectPage(selected);
    if (_pages.hasClients) {
      await _pages.animateToPage(
        selected,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _send() async {
    final session = _session;
    final text = _composer.text.trim();
    if (session == null || text.isEmpty) return;
    _composer.clear();
    session.composerText = '';
    await widget.controller.sendMessage(session, text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final selectedIndex = _normalizedIndex(_selectedIndex);
    final session = _session;
    final authBlocked =
        controller.connection == BridgeConnection.ready &&
        !controller.auth.authenticated;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Column(
      children: [
        PersistentActionBar(
          connection: controller.connection,
          session: session,
          socketConnected: controller.socketConnected,
          authBlocked: authBlocked,
          hasSessions: controller.sessions.isNotEmpty,
          onSessions: _showSessions,
          onNew: _newConversation,
          onSettings: widget.onSettings,
        ),
        Expanded(
          child: switch (controller.connection) {
            BridgeConnection.connecting => const ConnectionStateView(
              title: 'Connecting to Codex…',
              message: 'Looking for the shared app-server bridge.',
              loading: true,
            ),
            BridgeConnection.offline => ConnectionStateView(
              title: 'Codex is offline',
              message: controller.connectionError.isEmpty
                  ? 'The mobile app could not reach the Go bridge.'
                  : controller.connectionError,
              onRetry: controller.reconnect,
            ),
            BridgeConnection.ready when authBlocked => AuthView(
              auth: controller.auth,
              onRetry: controller.requestDeviceLogin,
            ),
            BridgeConnection.ready =>
              controller.sessions.isEmpty
                  ? ConnectionStateView(
                      title: 'No conversations yet',
                      message: 'Start a conversation in any workspace.',
                      onRetry: _newConversation,
                      retryLabel: 'New conversation',
                    )
                  : PageView.builder(
                      controller: _pages,
                      physics: const PageScrollPhysics(),
                      onPageChanged: _selectPage,
                      itemCount: controller.sessions.length,
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<String>) return null;
                        final prefix = widget.primary
                            ? 'primary-'
                            : 'secondary-';
                        if (!key.value.startsWith(prefix)) return null;
                        final localId = key.value.substring(prefix.length);
                        final index = controller.sessions.indexWhere(
                          (session) => session.localId == localId,
                        );
                        return index < 0 ? null : index;
                      },
                      itemBuilder: (context, index) => SessionPage(
                        key: ValueKey(
                          '${widget.primary ? 'primary' : 'secondary'}-${controller.sessions[index].localId}',
                        ),
                        session: controller.sessions[index],
                        onPrompt: (prompt) {
                          _composer.text = prompt;
                          _send();
                        },
                        onApproval: controller.decideApproval,
                      ),
                    ),
          },
        ),
        AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: ComposerBar(
            controller: _composer,
            focusNode: _composerFocus,
            session: session,
            sessionIndex: selectedIndex,
            sessionCount: controller.sessions.length,
            enabled:
                controller.connection == BridgeConnection.ready &&
                controller.auth.authenticated,
            onChanged: (value) {
              final current = _session;
              if (current != null) current.composerText = value;
            },
            onSend: _send,
            onStop: session == null
                ? null
                : () => controller.interrupt(session),
          ),
        ),
      ],
    );
  }
}
