import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
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
          final maximized = grid && MultiViewModel.maximized.value;
          final tiled = grid && !maximized;
          final full = Offset.zero & constraints.biggest;
          final cells = tiled
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
                rect: tiled ? cells[i] : full,
                child: Offstage(
                  offstage: !tiled && i != selected,
                  // The widget tree under each tile stays the same with the
                  // grid on or off, so toggling it doesn't remount a page.
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: tiled ? (_) => _onTilePointerDown(i) : null,
                    child: Stack(children: [
                      Positioned.fill(
                        // A tile that isn't focused gets no hover and no
                        // clicks: the first click only focuses it.
                        child: IgnorePointer(
                          ignoring: tiled && i != selected,
                          child: tabs[i].page,
                        ),
                      ),
                      if (grid)
                        ..._tileChrome(tabs[i].key, i == selected, maximized),
                    ]),
                  ),
                ),
              ),
          ]);
        }),
      ),
    );
  }

  List<Widget> _tileChrome(String key, bool focused, bool maximized) => [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: focused
                    ? Border.all(color: MyTheme.accent, width: 3)
                    : Border.all(color: Colors.white24),
              ),
            ),
          ),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: _TileBadge(tabKey: key, maximized: maximized),
          ),
        ),
      ];
}

/// Bottom-left badge of a tile: state dot, peer name, ping and the
/// maximise/restore icon.
class _TileBadge extends StatelessWidget {
  final String tabKey;
  final bool maximized;

  const _TileBadge({Key? key, required this.tabKey, required this.maximized})
      : super(key: key);

  static Widget _dot(Color color) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  @override
  Widget build(BuildContext context) {
    // The tile's page registers its FFI when it mounts, before its badge.
    final ffi =
        Get.isRegistered<FFI>(tag: tabKey) ? Get.find<FFI>(tag: tabKey) : null;
    const style = TextStyle(color: Colors.white, fontSize: 12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (ffi == null)
          _dot(Colors.grey)
        else
          Obx(() => _dot(ffi.ffiModel.pi.isSet.isTrue
              ? Colors.green
              : Colors.orange)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            DesktopTab.tablabelGetter(tabKey).value,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (ffi != null)
          ListenableBuilder(
            listenable: ffi.qualityMonitorModel,
            builder: (context, _) {
              final delay = ffi.qualityMonitorModel.data.delay;
              return delay == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text('${delay}ms',
                          style: style.copyWith(color: Colors.white70)),
                    );
            },
          ),
        const SizedBox(width: 6),
        Tooltip(
          message: translate(maximized ? 'Restore' : 'Maximize'),
          child: GestureDetector(
            onTap: () => MultiViewModel.maximized.toggle(),
            child: Icon(
              maximized ? Icons.fullscreen_exit : Icons.fullscreen,
              size: 16,
              color: Colors.white,
            ),
          ),
        ),
      ]),
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
        onTap: fits ? MultiViewModel.toggleGrid : null,
        isClose: false,
      );
    });
  }
}
