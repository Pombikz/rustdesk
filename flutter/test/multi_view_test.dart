import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/multi_view.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
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
}
