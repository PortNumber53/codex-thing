import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/codex_controller.dart';
import 'package:mobile/main.dart';
import 'package:mobile/models.dart';
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
    expect(find.text('Keep connected in background'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.backgroundConnectionEnabled, isFalse);
    expect(find.text('Settings updated.'), findsOneWidget);
  });

  testWidgets('session picker reorders without changing the selected session', (
    tester,
  ) async {
    final controller = CodexController(preview: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(CodexMobileApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sessions'));
    await tester.pumpAndSettle();

    final picker = find.byType(SessionPickerSheet);
    final reorderable = tester.widget<ReorderableListView>(
      find.descendant(of: picker, matching: find.byType(ReorderableListView)),
    );
    reorderable.onReorderItem!(0, 1);
    await tester.pumpAndSettle();

    expect(controller.sessions.first.title, 'Review backend changes');
    expect(controller.sessions.last.title, 'Build the mobile client');
    expect(controller.selectedSession?.title, 'Build the mobile client');
    expect(find.byTooltip('Reorder session'), findsNWidgets(2));
    final selectedTile = tester
        .widgetList<ListTile>(
          find.descendant(of: picker, matching: find.byType(ListTile)),
        )
        .where((tile) => tile.selected);
    expect(selectedTile, hasLength(1));

    Navigator.of(tester.element(picker)).pop();
    await tester.pumpAndSettle();

    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(pages.page, closeTo(1, .01));
  });

  testWidgets('composer stays above the software keyboard', (tester) async {
    final controller = CodexController(preview: true);
    addTearDown(controller.dispose);
    addTearDown(() => tester.view.resetViewInsets());

    await tester.pumpWidget(CodexMobileApp(controller: controller));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final composer = find.byType(ComposerBar);
    expect(composer, findsOneWidget);
    final composerContext = tester.element(composer);
    final keyboardTop =
        MediaQuery.sizeOf(composerContext).height -
        MediaQuery.viewInsetsOf(composerContext).bottom;
    expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(keyboardTop));
  });

  testWidgets(
    'opening and scrolling above the keyboard keeps the transcript bottom visible',
    (tester) async {
      final controller = CodexController(preview: true);
      controller.sessions.first.messages = List.generate(
        30,
        (index) => ChatItem(
          role: index.isEven ? 'user' : 'assistant',
          text:
              'Transcript entry $index with enough text to remain scrollable.',
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(() => tester.view.resetViewInsets());

      await tester.pumpWidget(CodexMobileApp(controller: controller));
      await tester.pumpAndSettle();

      final transcript = find.byType(CustomScrollView).first;
      final position = tester
          .widget<CustomScrollView>(transcript)
          .controller!
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();

      final composerField = find.descendant(
        of: find.byType(ComposerBar),
        matching: find.byType(TextField),
      );
      await tester.tap(composerField);
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      await tester.pumpAndSettle();

      expect(position.pixels, closeTo(position.maxScrollExtent, 1));
      expect(
        tester.widget<TextField>(composerField).focusNode?.hasFocus,
        isTrue,
      );

      await tester.drag(transcript, const Offset(0, -80));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(composerField).focusNode?.hasFocus,
        isTrue,
      );
    },
  );

  testWidgets(
    'sessions retain transcript position and offer a latest shortcut',
    (tester) async {
      final controller = CodexController(preview: true);
      controller.sessions.first.messages = List.generate(
        30,
        (index) => ChatItem(
          role: index.isEven ? 'user' : 'assistant',
          text: 'Scrollable session entry $index with a useful amount of text.',
        ),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(CodexMobileApp(controller: controller));
      await tester.pumpAndSettle();

      final firstTranscript = find.byType(CustomScrollView).first;
      final firstPosition = tester
          .widget<CustomScrollView>(firstTranscript)
          .controller!
          .position;
      firstPosition.jumpTo(firstPosition.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final savedOffset = firstPosition.pixels;

      expect(find.byTooltip('Scroll to latest'), findsOneWidget);

      await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
      await tester.pumpAndSettle();
      await tester.fling(find.byType(PageView), const Offset(500, 0), 1000);
      await tester.pumpAndSettle();

      expect(firstPosition.pixels, closeTo(savedOffset, 1));

      await tester.tap(find.byTooltip('Scroll to latest'));
      await tester.pumpAndSettle();

      expect(firstPosition.pixels, closeTo(firstPosition.maxScrollExtent, 1));
      expect(find.byTooltip('Scroll to latest'), findsNothing);
    },
  );

  testWidgets('large landscape displays show two independent conversations', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = CodexController(preview: true);
    final loadedSessions = List<MobileSession>.of(controller.sessions);
    controller.sessions.clear();
    addTearDown(controller.dispose);

    await tester.pumpWidget(CodexMobileApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byType(PersistentActionBar), findsNWidgets(2));
    expect(find.byType(ComposerBar), findsNWidgets(2));
    expect(find.byType(PageView), findsNothing);

    controller.sessions.addAll(loadedSessions);
    await controller.selectSession(0);
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsNWidgets(2));

    final pageViews = tester
        .widgetList<PageView>(find.byType(PageView))
        .toList();
    final primaryPages = pageViews[0].controller!;
    final secondaryPages = pageViews[1].controller!;
    expect(primaryPages.page, closeTo(0, .01));
    expect(secondaryPages.page, closeTo(1, .01));

    await tester.fling(find.byType(PageView).at(1), const Offset(500, 0), 1000);
    await tester.pumpAndSettle();

    expect(primaryPages.page, closeTo(0, .01));
    expect(secondaryPages.page, closeTo(0, .01));

    tester.view.physicalSize = const Size(800, 1200);
    await tester.pumpAndSettle();

    expect(find.byType(PersistentActionBar), findsOneWidget);
    expect(find.byType(ComposerBar), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);
  });
}
