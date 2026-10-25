import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/multi_view.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/multi_view_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends Fake implements RustdeskImpl {
  @override
  bool isIncomingOnly({dynamic hint}) => false;

  @override
  bool isOutgoingOnly({dynamic hint}) => false;

  @override
  String mainGetPeerOptionSync(
          {required String id, required String key, dynamic hint}) =>
      '';

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
}

class _Page extends StatefulWidget {
  final String label;

  const _Page(this.label, {Key? key}) : super(key: key);

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  Widget build(BuildContext context) => Text(widget.label);
}

TabInfo _tab(String label) => TabInfo(
    key: label, label: label, page: _Page(label, key: ValueKey('page-$label')));

State _pageState(WidgetTester tester, String label) =>
    tester.state(find.byKey(ValueKey('page-$label'), skipOffstage: false));

class _ClickPage extends StatelessWidget {
  final String label;
  final List<String> clicks;

  const _ClickPage(this.label, this.clicks, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => clicks.add(label),
        child: Text(label),
      );
}

DesktopTabController _gridController(List<TabInfo> tabs) {
  MultiViewModel.enabled = true;
  MultiViewModel.gridOn.value = true;
  final controller = DesktopTabController(tabType: DesktopTabType.remoteScreen);
  controller.state.update((s) => s!.tabs.addAll(tabs));
  return controller;
}

void main() {
  setUp(() => platformFFI.setBindingForTesting(_Binding()));

  tearDown(() {
    MultiViewModel.enabled = false;
    MultiViewModel.gridOn.value = false;
    MultiViewModel.maximized.value = false;
    MultiViewModel.setTileRects({});
    MultiViewModel.leader.value = null;
    MultiViewModel.notFollowing.clear();
    MultiViewModel.broadcastOn.value = false;
  });

  group('MultiViewModel.broadcastSnapshot', () {
    const tiles = [
      BroadcastTile('A', connected: true, viewOnly: false),
      BroadcastTile('B', connected: true, viewOnly: false),
      BroadcastTile('C', connected: true, viewOnly: false),
      BroadcastTile('D', connected: true, viewOnly: true),
    ];

    BroadcastSnapshot snapshot(
            {String focused = 'A', List<BroadcastTile> of = tiles}) =>
        MultiViewModel.broadcastSnapshot(
          grid: true,
          on: true,
          leader: 'A',
          focused: focused,
          notFollowing: {'C'},
          tiles: of,
        );

    test(
        'on with the leader focused sends to every following, connected follower that is not view-only',
        () {
      final on = snapshot();
      expect(on.state, BroadcastState.on);
      expect(on.leader, 'A');
      expect(on.followers, ['B']);

      final bDisconnected = snapshot(of: [
        tiles[0],
        const BroadcastTile('B', connected: false, viewOnly: false),
        ...tiles.skip(2),
      ]);
      expect(bDisconnected.followers, isEmpty);
    });

    test('a leader that is not focused or not connected pauses broadcast',
        () {
      final notFocused = snapshot(focused: 'B');
      final notConnected = snapshot(of: [
        const BroadcastTile('A', connected: false, viewOnly: false),
        ...tiles.skip(1),
      ]);
      for (final paused in [notFocused, notConnected]) {
        expect(paused.state, BroadcastState.paused);
        expect(paused.leader, isNull);
        expect(paused.followers, isEmpty);
      }
    });

    test(
        'turning the grid off turns broadcast off and keeps the leader and follow switches',
        () {
      MultiViewModel.enabled = true;
      MultiViewModel.gridOn.value = true;
      MultiViewModel.makeLeader('A');
      MultiViewModel.toggleFollow('C');
      expect(MultiViewModel.toggleBroadcast(), isTrue);

      MultiViewModel.toggleGrid();

      expect(MultiViewModel.broadcastOn.value, isFalse);
      final off = MultiViewModel.broadcastSnapshot(
        grid: MultiViewModel.isGrid(tiles.length),
        on: MultiViewModel.broadcastOn.value,
        leader: MultiViewModel.leader.value,
        focused: 'A',
        notFollowing: MultiViewModel.notFollowing,
        tiles: tiles,
      );
      expect(off.state, BroadcastState.off);
      expect(off.followers, isEmpty);
      expect(MultiViewModel.leader.value, 'A');
      expect(MultiViewModel.notFollowing.toSet(), {'C'});
    });
  });

  group('MultiViewModel.layout', () {
    const size = Size(800, 600);

    test('1 tab fills the area', () {
      expect(MultiViewModel.layout(1, size), [Offset.zero & size]);
    });

    test('2 tabs sit side by side', () {
      expect(MultiViewModel.layout(2, size), [
        const Rect.fromLTWH(0, 0, 400, 600),
        const Rect.fromLTWH(400, 0, 400, 600),
      ]);
    });

    test('3 and 4 tabs take the quadrants in tab order', () {
      const quadrants = [
        Rect.fromLTWH(0, 0, 400, 300),
        Rect.fromLTWH(400, 0, 400, 300),
        Rect.fromLTWH(0, 300, 400, 300),
        Rect.fromLTWH(400, 300, 400, 300),
      ];
      expect(MultiViewModel.layout(3, size), quadrants.sublist(0, 3));
      expect(MultiViewModel.layout(4, size), quadrants);
    });

    test('5 tabs make no grid', () {
      expect(MultiViewModel.layout(5, size), isEmpty);
    });
  });

  testWidgets(
      'a pointer-down on a tile that is not focused selects it and does not reach its page',
      (tester) async {
    final clicks = <String>[];
    final controller = _gridController([
      for (final label in ['A', 'B'])
        TabInfo(
            key: label,
            label: label,
            page: _ClickPage(label, clicks, key: ValueKey('page-$label'))),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: MultiViewStack(controller: controller),
    ));
    expect(find.byKey(const ValueKey('page-A')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-B')), findsOneWidget);
    final tileB = tester.getCenter(find.byKey(const ValueKey('page-B')));

    await tester.tapAt(tileB);
    await tester.pump();
    expect(controller.state.value.selected, 1);
    expect(clicks, isEmpty);

    await tester.tapAt(tileB);
    // Let DesktopTabController.jumpTo's delayed scroll run.
    await tester.pump(const Duration(milliseconds: 200));
    expect(clicks, ['B']);
  });

  testWidgets(
      'MultiViewStack shows only the selected tab and keeps every page mounted',
      (tester) async {
    final controller =
        DesktopTabController(tabType: DesktopTabType.remoteScreen);
    controller.state.update((s) => s!.tabs.addAll([_tab('A'), _tab('B')]));
    await tester.pumpWidget(MaterialApp(
      home: MultiViewStack(controller: controller),
    ));

    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsNothing);
    final stateA = _pageState(tester, 'A');
    final stateB = _pageState(tester, 'B');

    controller.state.update((s) => s!.selected = 1);
    await tester.pump();

    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsOneWidget);
    expect(_pageState(tester, 'A'), same(stateA));
    expect(_pageState(tester, 'B'), same(stateB));
  });

  testWidgets(
      'the maximise icon fills the window with its tile and restores the grid',
      (tester) async {
    final controller = _gridController([_tab('A'), _tab('B')]);
    await tester.pumpWidget(MaterialApp(
      home: MultiViewStack(controller: controller),
    ));
    const window = Rect.fromLTWH(0, 0, 800, 600);
    final tileB = find.byKey(const ValueKey('B'));
    expect(tester.getRect(tileB), const Rect.fromLTWH(400, 0, 400, 600));

    await tester.tap(
        find.descendant(of: tileB, matching: find.byIcon(Icons.fullscreen)));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('page-A')), findsNothing);
    expect(find.byKey(const ValueKey('page-B')), findsOneWidget);
    expect(tester.getRect(tileB), window);

    await tester.tap(find.descendant(
        of: tileB, matching: find.byIcon(Icons.fullscreen_exit)));
    await tester.pump();

    expect(find.byKey(const ValueKey('page-A')), findsOneWidget);
    expect(tester.getRect(tileB), const Rect.fromLTWH(400, 0, 400, 600));
  });

  testWidgets('with 3 tabs the empty fourth cell shows New Connection',
      (tester) async {
    final controller = _gridController([_tab('A'), _tab('B'), _tab('C')]);
    await tester.pumpWidget(MaterialApp(
      home: MultiViewStack(controller: controller),
    ));

    final cell = find.text('New Connection');
    expect(cell, findsOneWidget);
    expect(const Rect.fromLTWH(400, 300, 400, 300)
        .contains(tester.getCenter(cell)), isTrue);
  });
}
