import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models.dart';

void main() {
  test(
    'protocol user messages reconcile optimistic sends without duplicates',
    () {
      final session = MobileSession(localId: 'session')
        ..streaming = true
        ..messages = [
          const ChatItem(role: 'user', text: 'Run the tests'),
          const ChatItem(role: 'assistant'),
        ];

      session.reconcileUserMessage(
        id: 'user-1',
        text: 'Run the tests',
        claimOptimistic: true,
      );

      expect(session.messages, hasLength(2));
      expect(session.messages.first.id, 'user-1');

      session.reconcileUserMessage(
        id: 'user-1',
        text: 'Run the tests',
        claimOptimistic: false,
      );
      expect(session.messages, hasLength(2));
    },
  );

  test('identical prompts in separate turns remain separate messages', () {
    final session = MobileSession(localId: 'session')
      ..streaming = true
      ..messages = [
        const ChatItem(id: 'user-1', role: 'user', text: 'Continue'),
        const ChatItem(role: 'assistant', text: 'Done'),
        const ChatItem(role: 'user', text: 'Continue'),
        const ChatItem(role: 'assistant'),
      ];

    session.reconcileUserMessage(
      id: 'user-2',
      text: 'Continue',
      claimOptimistic: true,
    );

    expect(
      session.messages.where((message) => message.role == 'user'),
      hasLength(2),
    );
    expect(session.messages[0].id, 'user-1');
    expect(session.messages[2].id, 'user-2');

    session.reconcileUserMessage(
      id: 'user-3',
      text: 'Continue',
      claimOptimistic: false,
    );
    expect(
      session.messages.where((message) => message.role == 'user'),
      hasLength(3),
    );
  });

  test('idle thread status clears stale working and approval state', () {
    final session = MobileSession(localId: 'thread-1', threadId: 'thread-1')
      ..working = true
      ..active = true
      ..turnId = 'turn-1'
      ..activity = 'Waiting for approval'
      ..approvals = const [
        ApprovalRequest(id: 'approval-1', threadId: 'thread-1'),
      ]
      ..decidingApprovals.add('approval-1');

    session.applyThreadStatus('idle', const []);

    expect(session.working, isFalse);
    expect(session.active, isFalse);
    expect(session.turnId, isEmpty);
    expect(session.activity, isEmpty);
    expect(session.approvals, isEmpty);
    expect(session.decidingApprovals, isEmpty);
  });
}
