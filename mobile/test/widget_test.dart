import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/codex_controller.dart';
import 'package:mobile/main.dart';
import 'package:mobile/widgets.dart';

void main() {
  testWidgets('sessions fill the screen and switch with a horizontal swipe', (
    tester,
  ) async {
    final controller = CodexController(preview: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(CodexMobileApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Build the mobile client'), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byType(PersistentActionBar), findsOneWidget);
    expect(find.byType(ComposerBar), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Swipe sessions  ·  1 of 2'), findsOneWidget);

    await tester.tap(find.text('Sessions'));
    await tester.pumpAndSettle();

    final sessionPicker = find.byType(SessionPickerSheet);
    expect(
      find.descendant(
        of: sessionPicker,
        matching: find.text('/workspace/androidex'),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: sessionPicker,
        matching: find.text('Build the mobile client'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sessionPicker,
        matching: find.text('Review backend changes'),
      ),
      findsOneWidget,
    );

    final sessionActions = find.descendant(
      of: sessionPicker,
      matching: find.byTooltip('Session actions'),
    );
    expect(sessionActions, findsNWidgets(2));
    await tester.tap(sessionActions.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename session'));
    await tester.pumpAndSettle();

    final renameDialog = find.byType(RenameSessionDialog);
    expect(renameDialog, findsOneWidget);
    await tester.enterText(
      find.descendant(of: renameDialog, matching: find.byType(TextField)),
      'Mobile session name',
    );
    await tester.tap(
      find.descendant(
        of: renameDialog,
        matching: find.widgetWithText(FilledButton, 'Rename'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: sessionPicker,
        matching: find.text('Mobile session name'),
      ),
      findsOneWidget,
    );

    Navigator.of(tester.element(sessionPicker)).pop();
    await tester.pumpAndSettle();

    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Review backend changes'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Swipe sessions  ·  2 of 2'), findsOneWidget);
  });

  testWidgets('settings remains available while the bridge is connecting', (
    tester,
  ) async {
    final controller = CodexController(
      initialServerUrl: 'http://10.0.2.2:40001',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(CodexMobileApp(controller: controller));
    await tester.pump();

    expect(find.text('Connecting to Codex…'), findsOneWidget);
    expect(find.byType(PersistentActionBar), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Codex server'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
  });
}
