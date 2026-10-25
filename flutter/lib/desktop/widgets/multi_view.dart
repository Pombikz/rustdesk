import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/multi_view_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

const _kBroadcastColor = Color(0xFFFFA424);
const _kOnBroadcastColor = Color(0xFF1A1000);

/// The pointer that last went down on a badge control. The tile's own
/// pointer-down handler skips it, so marking a leader or switching follow
/// doesn't focus the tile, which would pause broadcast.
int? _badgeControlPointer;

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
  late final Worker _tabsWorker;

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
    _tabsWorker = ever(
        controller.state,
        (DesktopTabState state) =>
            MultiViewModel.tabsChanged([for (final t in state.tabs) t.key]));
  }

  @override
  void dispose() {
    _tabsWorker.dispose();
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

  void _onTilePointerDown(int index, PointerDownEvent event) {
    if (event.pointer == _badgeControlPointer) return;
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
                    onPointerDown:
                        tiled ? (e) => _onTilePointerDown(i, e) : null,
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
            if (tiled && tabs.length == 3)
              Positioned.fromRect(
                rect: MultiViewModel.layout(4, constraints.biggest)[3],
                child: const _EmptyCell(),
              ),
            Positioned(
              left: 0,
              top: 0,
              width: 0,
              height: 0,
              child: _BroadcastPush(controller: controller),
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
            child: _TileBadge(
                controller: controller, tabKey: key, maximized: maximized),
          ),
        ),
      ];
}

/// The fourth cell with 3 tabs: the tab bar's New Connection action.
class _EmptyCell extends StatelessWidget {
  const _EmptyCell({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton.icon(
        onPressed: () => rustDeskWinManager.call(
            WindowType.Main, kWindowMainWindowOnTop, ""),
        icon: const Icon(Icons.add, color: Colors.white70),
        label: Text(translate('New Connection'),
            style: const TextStyle(color: Colors.white70)),
      ),
    );
  }
}

/// Bottom-left badge of a tile: state dot, peer name, ping and the
/// maximise/restore icon.
class _TileBadge extends StatelessWidget {
  final DesktopTabController controller;
  final String tabKey;
  final bool maximized;

  const _TileBadge(
      {Key? key,
      required this.controller,
      required this.tabKey,
      required this.maximized})
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
        const SizedBox(width: 6),
        _BroadcastBuilder(
          controller: controller,
          builder: (snapshot) => _roleChips(snapshot, ffi),
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

  /// Before any leader is marked only the make-leader star shows. Then the
  /// leader shows its chip, and every other tile its follow chip and star.
  Widget _roleChips(BroadcastSnapshot snapshot, FFI? ffi) {
    final star = _badgeControl(
      tooltip: translate('Make leader'),
      onTap: () => MultiViewModel.makeLeader(tabKey),
      child: const Icon(Icons.star_border, size: 16, color: Colors.white54),
    );
    final leader = MultiViewModel.leader.value;
    if (leader == null) return star;
    final on = snapshot.state == BroadcastState.on;
    if (leader == tabKey) {
      return _chip(Icons.star, 'Leader',
          color: on ? _kOnBroadcastColor : _kBroadcastColor,
          border: _kBroadcastColor,
          fill: on ? _kBroadcastColor : null);
    }
    final Widget chip;
    if (ffi?.ffiModel.viewOnly == true) {
      chip = _chip(Icons.visibility, 'View Mode',
          color: const Color(0xFF999999),
          border: const Color(0xFF777777),
          dashed: true);
    } else if (MultiViewModel.notFollowing.contains(tabKey)) {
      chip = _chip(Icons.link_off, 'Not following',
          color: const Color(0xFF777777),
          border: const Color(0xFF555555),
          dashed: true);
    } else if (snapshot.followers.contains(tabKey)) {
      chip = _chip(Icons.link, 'Follow',
          color: _kOnBroadcastColor,
          border: _kBroadcastColor,
          fill: _kBroadcastColor);
    } else if (snapshot.state == BroadcastState.paused) {
      chip = _chip(Icons.link, 'Follow',
          color: _kBroadcastColor, border: _kBroadcastColor, dashed: true);
    } else {
      chip = _chip(Icons.link, 'Follow',
          color: const Color(0xFFCFD3D8), border: Colors.white24);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _badgeControl(
        onTap: () => MultiViewModel.toggleFollow(tabKey),
        child: chip,
      ),
      const SizedBox(width: 4),
      star,
    ]);
  }
}

Widget _badgeControl(
    {String? tooltip, required VoidCallback onTap, required Widget child}) {
  final control = Listener(
    onPointerDown: (e) => _badgeControlPointer = e.pointer,
    child: GestureDetector(onTap: onTap, child: child),
  );
  return tooltip == null ? control : Tooltip(message: tooltip, child: control);
}

Widget _chip(IconData icon, String label,
    {required Color color,
    required Color border,
    Color? fill,
    bool dashed = false}) {
  final chip = Container(
    padding: const EdgeInsets.fromLTRB(5, 1, 7, 1),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: dashed ? Colors.transparent : border),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: color),
      const SizedBox(width: 3),
      Text(translate(label),
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );
  return dashed
      ? CustomPaint(foregroundPainter: _DashedBorderPainter(border), child: chip)
      : chip;
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;

  const _DashedBorderPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5), const Radius.circular(10)));
    for (final metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 6) {
        canvas.drawPath(metric.extractPath(d, d + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

FFI? _tileFfi(String? key) => key != null && Get.isRegistered<FFI>(tag: key)
    ? Get.find<FFI>(tag: key)
    : null;

bool _tileConnected(String? key) =>
    _tileFfi(key)?.ffiModel.pi.isSet.isTrue ?? false;

String _tileName(String key) => DesktopTab.tablabelGetter(key).value;

String? _focusedKey(DesktopTabController controller) {
  final tabs = controller.state.value.tabs;
  final selected = controller.state.value.selected;
  return selected >= 0 && selected < tabs.length ? tabs[selected].key : null;
}

BroadcastSnapshot _broadcastSnapshot(DesktopTabController controller) {
  final tabs = controller.state.value.tabs;
  return MultiViewModel.broadcastSnapshot(
    grid: MultiViewModel.isGrid(tabs.length),
    on: MultiViewModel.broadcastOn.value,
    leader: MultiViewModel.leader.value,
    focused: _focusedKey(controller),
    notFollowing: MultiViewModel.notFollowing,
    tiles: [
      for (final tab in tabs)
        BroadcastTile(tab.key,
            connected: _tileConnected(tab.key),
            viewOnly: _tileFfi(tab.key)?.ffiModel.viewOnly ?? false),
    ],
  );
}

/// Rebuilds [builder] with the broadcast snapshot whenever it may change.
/// Tabs, focus, connection and the switches are observables; view-only is
/// only announced by each tile's [FfiModel].
class _BroadcastBuilder extends StatelessWidget {
  final DesktopTabController controller;
  final Widget Function(BroadcastSnapshot snapshot) builder;

  const _BroadcastBuilder(
      {Key? key, required this.controller, required this.builder})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final models = [
        for (final tab in controller.state.value.tabs)
          if (_tileFfi(tab.key) != null) _tileFfi(tab.key)!.ffiModel,
      ];
      return ListenableBuilder(
        listenable: Listenable.merge(models),
        builder: (context, _) =>
            Obx(() => builder(_broadcastSnapshot(controller))),
      );
    });
  }
}

/// Pushes the snapshot to Rust whenever it changes. Rust only ever sees
/// "these followers" or "none"; paused pushes none.
class _BroadcastPush extends StatelessWidget {
  final DesktopTabController controller;

  /// What Rust last got, so rebuilds that don't change it push nothing.
  static String? _pushed;

  const _BroadcastPush({Key? key, required this.controller}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _BroadcastBuilder(
      controller: controller,
      builder: (snapshot) {
        _push(snapshot);
        return const SizedBox.shrink();
      },
    );
  }

  void _push(BroadcastSnapshot snapshot) {
    final followers = [
      for (final key in snapshot.followers)
        if (_tileFfi(key) != null) _tileFfi(key)!.sessionId.toString(),
    ];
    // Rust ignores the leader of an empty snapshot, but the setter needs one.
    final leader = _tileFfi(snapshot.leader) ??
        controller.state.value.tabs
            .map((tab) => _tileFfi(tab.key))
            .whereType<FFI>()
            .firstOrNull;
    if (leader == null) return;
    final json = jsonEncode(followers);
    final pushed = followers.isEmpty ? '' : '${leader.sessionId} $json';
    if (pushed == _pushed) return;
    _pushed = pushed;
    bind.sessionSetInputBroadcast(leader: leader.sessionId, followers: json);
  }
}

/// Tab bar button that turns input broadcast on and off for this window,
/// shown only while the grid is.
class InputBroadcastButton extends StatelessWidget {
  final DesktopTabController controller;

  const InputBroadcastButton({Key? key, required this.controller})
      : super(key: key);

  void _toggle() {
    if (!MultiViewModel.toggleBroadcast()) {
      showToast(translate('Mark a leader first'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return _BroadcastBuilder(
      controller: controller,
      builder: (snapshot) {
        if (!MultiViewModel.isGrid(controller.length)) {
          return const SizedBox.shrink();
        }
        if (snapshot.state == BroadcastState.off) {
          return ActionIcon(
            message: 'Input broadcast',
            icon: Icons.cell_tower,
            onTap: _toggle,
            isClose: false,
          );
        }
        final on = snapshot.state == BroadcastState.on;
        final color = on ? _kOnBroadcastColor : _kBroadcastColor;
        return Tooltip(
          message: on ? translate('Input broadcast') : _pausedReason(),
          waitDuration: const Duration(seconds: 1),
          child: InkWell(
            onTap: _toggle,
            child: Container(
              height: kDesktopRemoteTabBarHeight - 1,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: on ? _kBroadcastColor : null,
                gradient: on
                    ? null
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: const Alignment(-0.8, -0.4),
                        colors: [
                          _kBroadcastColor.withOpacity(0.13),
                          _kBroadcastColor.withOpacity(0.13),
                          Colors.transparent,
                          Colors.transparent,
                        ],
                        stops: const [0, 0.5, 0.5, 1],
                        tileMode: TileMode.repeated,
                      ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(on ? Icons.cell_tower : Icons.pause_circle,
                    size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  translate(on ? 'On' : 'Paused').toUpperCase(),
                  style: TextStyle(
                      color: color, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  String _pausedReason() {
    final leader = MultiViewModel.leader.value;
    if (leader == null) return '';
    if (!_tileConnected(leader)) {
      return translate('{} (leader) is reconnecting')
          .replaceFirst('{}', _tileName(leader));
    }
    return translate('Focus is on {}; click {} to resume')
        .replaceFirst('{}', _tileName(_focusedKey(controller) ?? leader))
        .replaceFirst('{}', _tileName(leader));
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
