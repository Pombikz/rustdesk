import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/multi_view_model.dart';
import 'package:get/get.dart';

/// Renders the tabs of a remote window in one [Stack], each child keyed by
/// its tab key, so a page is never remounted when the selection or layout
/// changes. With the grid off only the selected tab is shown, full size;
/// with it on every tab is a tile and the selected tab is the focused tile.
class MultiViewStack extends StatefulWidget {
  final DesktopTabController controller;

  const MultiViewStack({Key? key, required this.controller}) : super(key: key);

  @override
  State<MultiViewStack> createState() => _MultiViewStackState();
}

class _MultiViewStackState extends State<MultiViewStack> {
  Function(String)? _onSelected;
  Widget? _focusedPage;

  DesktopTabController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Every selection change (tile click, tab click, tab shortcut, closed
    // tab) calls onSelected, and the window's handler there moves
    // CUR_SESSION_ID. Wrapping it lets the old tile leave first.
    _onSelected = controller.onSelected;
    controller.onSelected = _focusChanged;
    final tabs = controller.state.value.tabs;
    final selected = controller.state.value.selected;
    if (selected >= 0 && selected < tabs.length) {
      _focusedPage = tabs[selected].page;
    }
  }

  @override
  void dispose() {
    if (controller.onSelected == _focusChanged) {
      controller.onSelected = _onSelected;
    }
    super.dispose();
  }

  /// The old tile leaves before the new one is selected and takes focus.
  /// Otherwise the new tile takes the grab with the old tile's held keys
  /// still recorded, and those keys stay down on the old peer.
  void _focusChanged(String key) {
    final oldPage = _focusedPage;
    final newPage = controller.widget(key);
    _focusedPage = newPage;
    final grid = MultiViewModel.isGrid(controller.length);
    if (grid && oldPage is RemotePage && oldPage != newPage) {
      oldPage.multiViewLeave();
    }
    _onSelected?.call(key);
    if (grid && newPage is RemotePage) {
      newPage.multiViewFocus();
    }
  }

  void _onTilePointerDown(int index) {
    if (controller.state.value.selected != index) {
      controller.jumpTo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kColorCanvas,
      child: LayoutBuilder(
        builder: (context, constraints) => Obx(() {
          final tabs = controller.state.value.tabs;
          final selected = controller.state.value.selected;
          final grid = MultiViewModel.isGrid(tabs.length);
          final full = Offset.zero & constraints.biggest;
          final cells = grid
              ? MultiViewModel.layout(tabs.length, constraints.biggest)
              : <Rect>[];
          MultiViewModel.setTileRects({
            if (cells.length > 1)
              for (var i = 0; i < tabs.length; i++) tabs[i].key: cells[i],
          });
          return Stack(children: [
            for (var i = 0; i < tabs.length; i++)
              Positioned.fromRect(
                key: ValueKey(tabs[i].key),
                rect: grid ? cells[i] : full,
                child: Offstage(
                  offstage: !grid && i != selected,
                  // The widget tree under each tile stays the same with the
                  // grid on or off, so toggling it doesn't remount a page.
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: grid ? (_) => _onTilePointerDown(i) : null,
                    // A tile that isn't focused gets no hover and no clicks:
                    // the first click only focuses it.
                    child: IgnorePointer(
                      ignoring: grid && i != selected,
                      child: tabs[i].page,
                    ),
                  ),
                ),
              ),
          ]);
        }),
      ),
    );
  }
}

/// Tab bar button that turns the grid on and off for this window.
class MultiViewButton extends StatelessWidget {
  final DesktopTabController controller;

  const MultiViewButton({Key? key, required this.controller})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final fits = controller.length <= MultiViewModel.maxTiles;
      return ActionIcon(
        message: fits ? 'Multi-view' : 'Multi-view supports at most 4 tabs',
        icon: MultiViewModel.gridOn.value
            ? Icons.grid_view_sharp
            : Icons.grid_view_outlined,
        onTap: fits ? () => MultiViewModel.gridOn.toggle() : null,
        isClose: false,
      );
    });
  }
}
