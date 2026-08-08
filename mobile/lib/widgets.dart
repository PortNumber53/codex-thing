import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'codex_controller.dart';
import 'models.dart';

const _muted = Color(0xFFA5ABB6);
const _border = Color(0xFF2A2E37);
const _surface = Color(0xFF171A20);
const _raised = Color(0xFF20242C);
const _accent = Color(0xFFB7F7D2);
const _danger = Color(0xFFFFA8A8);

class SessionPage extends StatefulWidget {
  const SessionPage({
    super.key,
    required this.session,
    required this.onPrompt,
    required this.onApproval,
  });

  final MobileSession session;
  final ValueChanged<String> onPrompt;
  final Future<void> Function(
    MobileSession,
    ApprovalRequest,
    String, {
    Map<String, List<String>>? answers,
    JsonMap? content,
  })
  onApproval;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage>
    with AutomaticKeepAliveClientMixin<SessionPage> {
  final ScrollController _scroll = ScrollController();
  int _lastItemCount = 0;
  int _lastTextLength = 0;
  double _lastKeyboardInset = 0;
  bool _pinToBottomDuringKeyboardOpen = false;
  bool _bottomPinScheduled = false;
  bool _scrollAffordanceScheduled = false;
  bool _showScrollToBottom = false;
  bool _followLatest = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateScrollAffordance);
    _updateScrollAffordanceAfterLayout();
  }

  void _updateScrollAffordance() {
    if (!mounted || !_scroll.hasClients) return;
    final shouldShow = _scroll.position.extentAfter > 160;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  void _updateScrollAffordanceAfterLayout() {
    if (_scrollAffordanceScheduled) return;
    _scrollAffordanceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollAffordanceScheduled = false;
      _updateScrollAffordance();
    });
  }

  Future<void> _scrollToBottom() async {
    if (!_scroll.hasClients) return;
    _followLatest = true;
    await _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    _pinBottomAfterLayout();
  }

  void _pinBottomAfterLayout() {
    if (_bottomPinScheduled) return;
    _bottomPinScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomPinScheduled = false;
      if (!mounted ||
          (!_pinToBottomDuringKeyboardOpen && !_followLatest) ||
          !_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboardInset == _lastKeyboardInset) return;

    final keyboardOpening = keyboardInset > _lastKeyboardInset;
    if (_lastKeyboardInset == 0 && keyboardInset > 0) {
      _pinToBottomDuringKeyboardOpen =
          !_scroll.hasClients ||
          _scroll.position.maxScrollExtent - _scroll.position.pixels <= 48;
    }
    _lastKeyboardInset = keyboardInset;

    if (keyboardOpening && _pinToBottomDuringKeyboardOpen) {
      _pinBottomAfterLayout();
    } else if (keyboardInset == 0) {
      _pinToBottomDuringKeyboardOpen = false;
    }
  }

  @override
  void didUpdateWidget(covariant SessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count =
        widget.session.messages.length + widget.session.approvals.length;
    final textLength = widget.session.messages.fold<int>(
      0,
      (sum, message) => sum + message.text.length + message.output.length,
    );
    if (count != _lastItemCount || textLength != _lastTextLength) {
      _lastItemCount = count;
      _lastTextLength = textLength;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_updateScrollAffordance);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final session = widget.session;
    return session.loading && !session.loaded
        ? const Center(child: CircularProgressIndicator())
        : Stack(
            fit: StackFit.expand,
            children: [
              NotificationListener<UserScrollNotification>(
                onNotification: (notification) {
                  if (notification.direction != ScrollDirection.idle) {
                    _followLatest = false;
                    _pinToBottomDuringKeyboardOpen = false;
                  }
                  return false;
                },
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    _updateScrollAffordanceAfterLayout();
                    if ((_lastKeyboardInset > 0 &&
                            _pinToBottomDuringKeyboardOpen) ||
                        _followLatest) {
                      _pinBottomAfterLayout();
                    }
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _scroll,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    slivers: [
                      if (session.error.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _ReadableWidth(
                            child: _InlineError(message: session.error),
                          ),
                        ),
                      if (session.messages.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: EmptyConversation(onPrompt: widget.onPrompt),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                          sliver: SliverList.builder(
                            itemCount: session.messages.length,
                            itemBuilder: (context, index) => _ReadableWidth(
                              child: TranscriptItem(
                                item: session.messages[index],
                                isLast: index == session.messages.length - 1,
                              ),
                            ),
                          ),
                        ),
                      if (session.activity.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _ReadableWidth(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                              child: Row(
                                children: [
                                  const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.8,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    session.activity,
                                    style: const TextStyle(color: _muted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (session.approvals.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          sliver: SliverList.builder(
                            itemCount: session.approvals.length,
                            itemBuilder: (context, index) {
                              final approval = session.approvals[index];
                              return _ReadableWidth(
                                child: ApprovalCard(
                                  key: ValueKey(approval.id),
                                  approval: approval,
                                  deciding: session.decidingApprovals.contains(
                                    approval.id,
                                  ),
                                  onDecision: (decision, {answers, content}) =>
                                      widget.onApproval(
                                        session,
                                        approval,
                                        decision,
                                        answers: answers,
                                        content: content,
                                      ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_showScrollToBottom)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    heroTag: null,
                    onPressed: _scrollToBottom,
                    tooltip: 'Scroll to latest',
                    backgroundColor: _raised,
                    foregroundColor: _accent,
                    child: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ),
            ],
          );
  }
}

class PersistentActionBar extends StatelessWidget {
  const PersistentActionBar({
    super.key,
    required this.connection,
    required this.session,
    required this.socketConnected,
    required this.authBlocked,
    required this.hasSessions,
    required this.onSessions,
    required this.onNew,
    required this.onSettings,
  });

  final BridgeConnection connection;
  final MobileSession? session;
  final bool socketConnected;
  final bool authBlocked;
  final bool hasSessions;
  final VoidCallback onSessions;
  final VoidCallback onNew;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
    decoration: const BoxDecoration(
      color: Color(0xFF0E1014),
      border: Border(bottom: BorderSide(color: _border)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final showLabels = constraints.maxWidth >= 600;
        final ready = connection == BridgeConnection.ready && !authBlocked;
        final title = ready && session != null ? session!.title : 'Codex Local';
        final subtitle = switch (connection) {
          BridgeConnection.connecting => 'Connecting to app-server',
          BridgeConnection.offline => 'App-server offline',
          BridgeConnection.ready when authBlocked => 'Sign in required',
          BridgeConnection.ready when session?.working == true =>
            'Codex is working',
          BridgeConnection.ready =>
            session == null
                ? 'Ready for a new conversation'
                : _workspaceName(session!.workspace),
        };
        final statusColor = switch (connection) {
          BridgeConnection.connecting => const Color(0xFFFFC46B),
          BridgeConnection.offline => _danger,
          BridgeConnection.ready when authBlocked => const Color(0xFFFFC46B),
          BridgeConnection.ready when session?.working == true => _accent,
          BridgeConnection.ready when socketConnected => const Color(
            0xFF74D7A0,
          ),
          BridgeConnection.ready => const Color(0xFFFFC46B),
        };
        Widget action({
          required IconData icon,
          required String label,
          required VoidCallback? onPressed,
        }) => showLabels
            ? TextButton.icon(
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              )
            : IconButton(
                onPressed: onPressed,
                tooltip: label,
                icon: Icon(icon),
              );

        return Row(
          children: [
            action(
              icon: Icons.view_carousel_outlined,
              label: 'Sessions',
              onPressed: ready && hasSessions ? onSessions : null,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            action(
              icon: Icons.add_comment_outlined,
              label: 'New',
              onPressed: ready && session?.working != true ? onNew : null,
            ),
            action(icon: Icons.tune, label: 'Settings', onPressed: onSettings),
          ],
        );
      },
    ),
  );
}

class ComposerBar extends StatelessWidget {
  const ComposerBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.session,
    required this.sessionIndex,
    required this.sessionCount,
    required this.enabled,
    required this.onChanged,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final MobileSession? session;
  final int sessionIndex;
  final int sessionCount;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final working = session?.working == true;
    return Material(
      color: const Color(0xFF111318),
      elevation: 18,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.swipe, size: 15, color: _muted),
                    const SizedBox(width: 7),
                    Text(
                      sessionCount > 0
                          ? 'Swipe sessions  ·  ${sessionIndex + 1} of $sessionCount'
                          : 'Codex local',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                    const Spacer(),
                    if (session?.active == true)
                      const Text(
                        'ACTIVE',
                        style: TextStyle(
                          color: _accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        enabled: enabled && !working && session != null,
                        onChanged: onChanged,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          hintText: !enabled
                              ? 'Connect and sign in to continue'
                              : working
                              ? 'Codex is working…'
                              : 'Message Codex…',
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 9),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) => IconButton.filled(
                        onPressed: working
                            ? onStop
                            : enabled && value.text.trim().isNotEmpty
                            ? onSend
                            : null,
                        tooltip: working ? 'Interrupt' : 'Send',
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(48),
                          backgroundColor: working
                              ? const Color(0xFF4C2528)
                              : _accent,
                          foregroundColor: working
                              ? _danger
                              : const Color(0xFF092016),
                          disabledBackgroundColor: const Color(0xFF252931),
                        ),
                        icon: Icon(
                          working ? Icons.stop_rounded : Icons.arrow_upward,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyConversation extends StatelessWidget {
  const EmptyConversation({super.key, required this.onPrompt});

  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
    child: _ReadableWidth(
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: _raised,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _border),
            ),
            child: const Icon(Icons.auto_awesome, color: _accent, size: 28),
          ),
          const SizedBox(height: 24),
          const Text(
            'What should we build?',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          const Text(
            'Chat with Codex in this workspace. Swipe sideways whenever you want to move to another session.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, height: 1.5),
          ),
          const SizedBox(height: 28),
          _PromptTile(
            title: 'Explore this codebase',
            subtitle: 'Map the architecture and important entry points.',
            onTap: onPrompt,
          ),
          _PromptTile(
            title: 'Build a feature',
            subtitle:
                'Describe what you want changed and Codex can implement it.',
            onTap: onPrompt,
          ),
          _PromptTile(
            title: 'Debug an issue',
            subtitle: 'Share an error or unexpected behavior to investigate.',
            onTap: onPrompt,
          ),
        ],
      ),
    ),
  );
}

class _ReadableWidth extends StatelessWidget {
  const _ReadableWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: child,
    ),
  );
}

class _PromptTile extends StatelessWidget {
  const _PromptTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: InkWell(
      onTap: () => onTap(subtitle),
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, size: 18, color: _muted),
          ],
        ),
      ),
    ),
  );
}

class TranscriptItem extends StatelessWidget {
  const TranscriptItem({super.key, required this.item, required this.isLast});

  final ChatItem item;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    if (item.kind == 'command') return CommandCard(item: item);
    if (item.kind == 'notice') {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2117),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF5B4325)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, color: Color(0xFFFFC46B), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(item.text, style: const TextStyle(height: 1.4)),
            ),
          ],
        ),
      );
    }

    final user = item.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (user ? .86 : 1),
        ),
        margin: const EdgeInsets.only(bottom: 18),
        padding: user ? const EdgeInsets.all(14) : EdgeInsets.zero,
        decoration: user
            ? BoxDecoration(
                color: const Color(0xFF242A31),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(5),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
                border: Border.all(color: const Color(0xFF343B45)),
              )
            : null,
        child: item.text.isEmpty && isLast
            ? const _ThinkingDots()
            : MarkdownBody(
                data: item.text,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    height: 1.48,
                    color: item.error ? _danger : null,
                    fontSize: 15,
                  ),
                  code: const TextStyle(
                    fontFamily: 'monospace',
                    color: Color(0xFFE4E9F1),
                    backgroundColor: _raised,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: const Color(0xFF111318),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _border),
                  ),
                  blockquoteDecoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: _accent, width: 3)),
                  ),
                  a: const TextStyle(color: _accent),
                ),
                onTapLink: (_, href, _) async {
                  final uri = Uri.tryParse(href ?? '');
                  if (uri != null) await launchUrl(uri);
                },
              ),
      ),
    );
  }
}

class _ThinkingDots extends StatelessWidget {
  const _ThinkingDots();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 8),
    child: SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

class CommandCard extends StatefulWidget {
  const CommandCard({super.key, required this.item});

  final ChatItem item;

  @override
  State<CommandCard> createState() => _CommandCardState();
}

class _CommandCardState extends State<CommandCard> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final lines = item.output.split('\n');
    final needsExpansion = lines.length > 12 || item.output.length > 2200;
    var output = item.output;
    if (!expanded && needsExpansion) {
      output = lines.take(12).join('\n');
      if (output.length > 2200) output = '${output.substring(0, 2200)}…';
    }
    final failed =
        item.status == 'failed' ||
        (item.exitCode != null && item.exitCode != 0);
    final running = item.status == 'inProgress';
    final label = running
        ? 'Running'
        : failed
        ? 'Command failed'
        : item.status == 'declined'
        ? 'Command declined'
        : 'Ran';
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF13161B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: failed ? const Color(0xFF6D3538) : _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 9),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 17,
                  color: failed ? _danger : _accent,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (item.exitCode != null)
                  Text(
                    'exit ${item.exitCode}',
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
              ],
            ),
          ),
          Container(
            color: const Color(0xFF0B0D10),
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              '\$ ${item.command.isEmpty ? 'Command' : item.command}',
              style: const TextStyle(fontFamily: 'monospace', height: 1.45),
            ),
          ),
          if (item.cwd.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 0),
              child: Text(
                item.cwd,
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
            ),
          if (output.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                output,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Color(0xFFB8BFCA),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          if (needsExpansion)
            TextButton(
              onPressed: () => setState(() => expanded = !expanded),
              child: Text(expanded ? 'Collapse output' : 'Show full output'),
            ),
        ],
      ),
    );
  }
}

class ApprovalCard extends StatefulWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    required this.deciding,
    required this.onDecision,
  });

  final ApprovalRequest approval;
  final bool deciding;
  final Future<void> Function(
    String decision, {
    Map<String, List<String>>? answers,
    JsonMap? content,
  })
  onDecision;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  final Map<String, String> answers = {};

  @override
  Widget build(BuildContext context) {
    final approval = widget.approval;
    if (approval.kind == 'userInput') return _buildQuestions(context);
    final title = switch (approval.kind) {
      'fileChange' => 'Review workspace changes',
      'permissions' => 'Additional permissions requested',
      'mcpElicitation' =>
        '${approval.serverName.isEmpty ? 'An MCP server' : approval.serverName} needs approval',
      _ => 'Command approval required',
    };
    final detail = switch (approval.kind) {
      'fileChange' =>
        approval.grantRoot.isEmpty
            ? 'Apply the pending file changes'
            : 'Allow changes under ${approval.grantRoot}',
      'permissions' => prettyJson(approval.permissions),
      'mcpElicitation' => approval.message,
      _ => approval.command,
    };
    return _ApprovalShell(
      title: title,
      reason: approval.reason,
      detail: detail,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: widget.deciding
                ? null
                : () => widget.onDecision('accept'),
            child: Text(widget.deciding ? 'Waiting for Codex…' : 'Allow once'),
          ),
          const SizedBox(height: 8),
          if (approval.kind == 'mcpElicitation')
            OutlinedButton(
              onPressed: widget.deciding
                  ? null
                  : () => widget.onDecision('decline'),
              child: const Text('Continue without it'),
            )
          else
            OutlinedButton(
              onPressed: widget.deciding
                  ? null
                  : () => widget.onDecision('always'),
              child: Text(
                approval.proposedExecPrefix.isEmpty
                    ? 'Allow for this session'
                    : 'Always allow ${approval.proposedExecPrefix.join(' ')}',
              ),
            ),
          TextButton(
            onPressed: widget.deciding
                ? null
                : () => widget.onDecision(
                    approval.kind == 'permissions' ? 'decline' : 'cancel',
                  ),
            style: TextButton.styleFrom(foregroundColor: _danger),
            child: const Text('Deny and stop'),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestions(BuildContext context) {
    final complete = widget.approval.questions.every(
      (question) => (answers[question.id] ?? '').trim().isNotEmpty,
    );
    return _ApprovalShell(
      title: 'Codex needs your input',
      reason: 'Answer to continue this turn.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final question in widget.approval.questions) ...[
            if (question.header.isNotEmpty)
              Text(
                question.header.toUpperCase(),
                style: const TextStyle(
                  color: _accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .8,
                ),
              ),
            const SizedBox(height: 6),
            Text(question.question),
            const SizedBox(height: 8),
            for (final option in question.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: OutlinedButton(
                  onPressed: widget.deciding
                      ? null
                      : () =>
                            setState(() => answers[question.id] = option.label),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    backgroundColor: answers[question.id] == option.label
                        ? const Color(0xFF26372E)
                        : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(option.label),
                        if (option.description.isNotEmpty)
                          Text(
                            option.description,
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            TextFormField(
              initialValue: answers[question.id] ?? '',
              enabled: !widget.deciding,
              obscureText: question.secret,
              onChanged: (value) =>
                  setState(() => answers[question.id] = value),
              decoration: InputDecoration(
                hintText: question.options.isEmpty
                    ? 'Type your answer'
                    : 'Or type another answer',
              ),
            ),
            const SizedBox(height: 18),
          ],
          FilledButton(
            onPressed: widget.deciding || !complete
                ? null
                : () => widget.onDecision(
                    'submit',
                    answers: {
                      for (final entry in answers.entries)
                        entry.key: [entry.value.trim()],
                    },
                  ),
            child: Text(
              widget.deciding ? 'Waiting for Codex…' : 'Submit answers',
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalShell extends StatelessWidget {
  const _ApprovalShell({
    required this.title,
    required this.child,
    this.reason = '',
    this.detail = '',
  });

  final String title;
  final String reason;
  final String detail;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF252016),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF5C4926)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.shield_outlined, color: Color(0xFFFFC46B)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(reason, style: const TextStyle(color: _muted, height: 1.4)),
        ],
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF111318),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              detail,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
        const SizedBox(height: 14),
        child,
      ],
    ),
  );
}

class AuthView extends StatelessWidget {
  const AuthView({super.key, required this.auth, required this.onRetry});

  final AuthSnapshot auth;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
    child: Column(
      children: [
        const Icon(Icons.lock_open_rounded, size: 54, color: _accent),
        const SizedBox(height: 22),
        Text(
          auth.pending
              ? 'Sign in to continue'
              : auth.busy
              ? 'Checking your Codex login…'
              : 'Codex needs you to sign in',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Text(
          auth.message.isEmpty
              ? 'Authenticate the shared Codex app-server to use every connected client.'
              : auth.message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, height: 1.5),
        ),
        const SizedBox(height: 26),
        if (auth.pending) ...[
          FilledButton.icon(
            onPressed: () async {
              final uri = Uri.tryParse(auth.verificationUrl);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_browser),
            label: const Text('Open OpenAI sign-in page'),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 15, 10, 15),
            decoration: BoxDecoration(
              color: _raised,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    auth.userCode,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: auth.userCode));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy code',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Waiting for sign-in to complete…'),
            ],
          ),
        ] else if (auth.busy)
          const CircularProgressIndicator()
        else
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.key),
            label: const Text('Get a sign-in code'),
          ),
      ],
    ),
  );
}

class ConnectionStateView extends StatelessWidget {
  const ConnectionStateView({
    super.key,
    required this.title,
    required this.message,
    this.loading = false,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.onSettings,
  });

  final String title;
  final String message;
  final bool loading;
  final VoidCallback? onRetry;
  final String retryLabel;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Icon(
            loading ? Icons.sync : Icons.cloud_off_outlined,
            size: 52,
            color: loading ? _accent : _muted,
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, height: 1.45),
          ),
          const SizedBox(height: 24),
          if (loading) const CircularProgressIndicator(),
          if (onRetry != null)
            FilledButton(onPressed: onRetry, child: Text(retryLabel)),
          if (onSettings != null)
            TextButton.icon(
              onPressed: onSettings,
              icon: const Icon(Icons.tune),
              label: const Text('Server settings'),
            ),
        ],
      ),
    ),
  );
}

class SessionPickerSheet extends StatefulWidget {
  const SessionPickerSheet({
    super.key,
    required this.sessions,
    required this.selectedIndex,
    required this.onNew,
    required this.onRename,
    required this.onReorder,
  });

  final List<MobileSession> sessions;
  final int selectedIndex;
  final VoidCallback onNew;
  final Future<void> Function(MobileSession session, String name) onRename;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  State<SessionPickerSheet> createState() => _SessionPickerSheetState();
}

class _SessionPickerSheetState extends State<SessionPickerSheet> {
  late final String _selectedSessionId;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selectedSessionId = widget.sessions.isEmpty
        ? ''
        : widget
              .sessions[widget.selectedIndex.clamp(
                0,
                widget.sessions.length - 1,
              )]
              .localId;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _rename(MobileSession session) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => RenameSessionDialog(initialName: session.title),
    );
    if (!mounted || name == null) return;
    try {
      await widget.onRename(session, name);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Session renamed.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not rename session: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final visibleSessions = <MapEntry<int, MobileSession>>[];
    for (var index = 0; index < widget.sessions.length; index += 1) {
      final session = widget.sessions[index];
      final searchable = [
        session.title,
        session.workspace,
        session.preview,
      ].join('\n').toLowerCase();
      if (query.isEmpty || searchable.contains(query)) {
        visibleSessions.add(MapEntry(index, session));
      }
    }
    final filtering = query.isNotEmpty;

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .68,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 12, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Sessions',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: widget.onNew,
                    icon: const Icon(Icons.add),
                    tooltip: 'New conversation',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const ValueKey('session-search-field'),
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                autocorrect: false,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search sessions',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: filtering
                      ? IconButton(
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                          tooltip: 'Clear session search',
                        )
                      : null,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visibleSessions.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No sessions match your search.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _muted),
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      itemCount: visibleSessions.length,
                      buildDefaultDragHandles: false,
                      onReorderItem: (oldIndex, newIndex) {
                        if (filtering) return;
                        widget.onReorder(oldIndex, newIndex);
                        setState(() {});
                      },
                      itemBuilder: (context, index) {
                        final entry = visibleSessions[index];
                        final originalIndex = entry.key;
                        final session = entry.value;
                        final workspace = session.workspace.trim();
                        final detail = session.working
                            ? 'Codex is working'
                            : session.preview.trim();
                        final selected = session.localId == _selectedSessionId;
                        return Column(
                          key: ValueKey(session.localId),
                          children: [
                            ListTile(
                              selected: selected,
                              isThreeLine: detail.isNotEmpty,
                              leading: CircleAvatar(
                                backgroundColor: session.working
                                    ? const Color(0xFF294A38)
                                    : _raised,
                                child: Icon(
                                  session.working
                                      ? Icons.bolt
                                      : Icons.chat_bubble_outline,
                                  color: session.working ? _accent : _muted,
                                  size: 19,
                                ),
                              ),
                              title: Text(
                                session.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    workspace.isEmpty
                                        ? 'Workspace not reported'
                                        : workspace,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _accent,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (detail.isNotEmpty)
                                    Text(
                                      detail,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (selected)
                                    const Icon(Icons.check, color: _accent),
                                  PopupMenuButton<String>(
                                    enabled:
                                        session.threadId.isNotEmpty &&
                                        !session.draft,
                                    tooltip: 'Session actions',
                                    onSelected: (action) {
                                      if (action == 'rename') _rename(session);
                                    },
                                    itemBuilder: (context) => const [
                                      PopupMenuItem(
                                        value: 'rename',
                                        child: ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          leading: Icon(Icons.edit_outlined),
                                          title: Text('Rename session'),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (!filtering)
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: const Tooltip(
                                        message: 'Reorder session',
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 12,
                                          ),
                                          child: Icon(
                                            Icons.drag_handle,
                                            color: _muted,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              onTap: () =>
                                  Navigator.pop(context, originalIndex),
                            ),
                            const Divider(height: 1, indent: 72),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class RenameSessionDialog extends StatefulWidget {
  const RenameSessionDialog({super.key, required this.initialName});

  final String initialName;

  @override
  State<RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<RenameSessionDialog> {
  late final TextEditingController name;
  String error = '';

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initialName);
    name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: name.text.length,
    );
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _submit() {
    final value = name.text.trim();
    if (value.isEmpty) {
      setState(() => error = 'Enter a session name.');
      return;
    }
    if (value.runes.length > 200) {
      setState(() => error = 'Use 200 characters or fewer.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename session'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'This name will appear in every connected Codex client.',
          style: TextStyle(color: _muted, height: 1.4),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: name,
          autofocus: true,
          maxLength: 200,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (error.isNotEmpty) setState(() => error = '');
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Session name',
            errorText: error.isEmpty ? null : error,
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Rename')),
    ],
  );
}

class WorkspacePickerSheet extends StatefulWidget {
  const WorkspacePickerSheet({
    super.key,
    required this.controller,
    required this.initialPath,
  });

  final CodexController controller;
  final String initialPath;

  @override
  State<WorkspacePickerSheet> createState() => _WorkspacePickerSheetState();
}

class _WorkspacePickerSheetState extends State<WorkspacePickerSheet> {
  late final TextEditingController path;
  List<JsonMap> suggestions = [];
  Timer? debounce;
  int requestGeneration = 0;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    path = TextEditingController(text: widget.initialPath);
  }

  @override
  void dispose() {
    debounce?.cancel();
    path.dispose();
    super.dispose();
  }

  void changed(String value) {
    debounce?.cancel();
    final generation = ++requestGeneration;
    debounce = Timer(const Duration(milliseconds: 180), () async {
      if (!value.trim().startsWith('/')) {
        if (mounted) setState(() => suggestions = []);
        return;
      }
      setState(() => loading = true);
      try {
        final result = await widget.controller.completeWorkspace(value.trim());
        if (mounted && generation == requestGeneration) {
          setState(() => suggestions = result);
        }
      } catch (_) {
        if (mounted && generation == requestGeneration) {
          setState(() => suggestions = []);
        }
      } finally {
        if (mounted && generation == requestGeneration) {
          setState(() => loading = false);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      8,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 18,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'New conversation',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Choose the workspace Codex can modify.',
          style: TextStyle(color: _muted),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: path,
          autofocus: true,
          onChanged: changed,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Absolute workspace path',
            suffixIcon: loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        if (suggestions.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: suggestions.length,
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(jsonString(suggestion['name'])),
                  subtitle: Text(
                    jsonString(suggestion['path']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    path.text = jsonString(suggestion['path']);
                    setState(() => suggestions = []);
                  },
                );
              },
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: path.text.trim().startsWith('/')
              ? () => Navigator.pop(context, path.text.trim())
              : null,
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Open conversation'),
        ),
      ],
    ),
  );
}

class ServerSettingsResult {
  const ServerSettingsResult({
    required this.url,
    required this.backgroundConnectionEnabled,
  });

  final String url;
  final bool backgroundConnectionEnabled;
}

class ServerSettingsDialog extends StatefulWidget {
  const ServerSettingsDialog({
    super.key,
    required this.initialUrl,
    required this.initialBackgroundConnectionEnabled,
  });

  final String initialUrl;
  final bool initialBackgroundConnectionEnabled;

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late final TextEditingController url;
  late bool backgroundConnectionEnabled;
  String error = '';

  @override
  void initState() {
    super.initState();
    url = TextEditingController(text: widget.initialUrl);
    backgroundConnectionEnabled = widget.initialBackgroundConnectionEnabled;
  }

  @override
  void dispose() {
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Codex server'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Use the Go bridge address reachable from this device. Android emulators use 10.0.2.2 for the development machine.',
          style: TextStyle(color: _muted, height: 1.4),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: url,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Server URL',
            hintText: 'http://host:40001',
            errorText: error.isEmpty ? null : error,
          ),
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: backgroundConnectionEnabled,
          onChanged: (value) {
            setState(() => backgroundConnectionEnabled = value);
          },
          title: const Text('Keep connected in background'),
          subtitle: const Text(
            'Shows an ongoing Android notification while Codex keeps live sessions connected.',
            style: TextStyle(color: _muted, height: 1.35),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final value = url.text.trim();
          final parsed = Uri.tryParse(value);
          if (parsed == null ||
              !parsed.hasAuthority ||
              (parsed.scheme != 'http' && parsed.scheme != 'https')) {
            setState(() => error = 'Enter a complete http:// or https:// URL.');
            return;
          }
          Navigator.pop(
            context,
            ServerSettingsResult(
              url: value,
              backgroundConnectionEnabled: backgroundConnectionEnabled,
            ),
          );
        },
        child: const Text('Save'),
      ),
    ],
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF351D20),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF6D3538)),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: _danger, size: 18),
        const SizedBox(width: 9),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

String _workspaceName(String path) {
  final pieces = path.split('/').where((part) => part.isNotEmpty).toList();
  return pieces.isEmpty ? 'Workspace' : pieces.last;
}
