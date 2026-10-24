import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:get/get.dart';

/// Renders the tabs of a remote window in one [Stack], each child keyed by
/// its tab key, so a page is never remounted when the selection or layout
/// changes. Only the selected tab is shown, full size.
class MultiViewStack extends StatelessWidget {
  final DesktopTabController controller;

  const MultiViewStack({Key? key, required this.controller}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kColorCanvas,
      child: Obx(() {
        final tabs = controller.state.value.tabs;
        final selected = controller.state.value.selected;
        return Stack(children: [
          for (var i = 0; i < tabs.length; i++)
            Positioned.fill(
              key: ValueKey(tabs[i].key),
              child: Offstage(offstage: i != selected, child: tabs[i].page),
            ),
        ]);
      }),
    );
  }
}
