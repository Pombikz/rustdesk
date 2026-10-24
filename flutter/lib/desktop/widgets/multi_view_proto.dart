// PROTOTYPE, never merge. See models/multi_view_proto_model.dart.

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/multi_view_proto_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

/// Renders the remote tabs either one at a time (grid off) or as tiles.
/// All tiles stay in one keyed [Stack] in both modes, so switching the grid
/// on and off never rebuilds a session's page.
class MultiViewProtoStack extends StatefulWidget {
  final DesktopTabController controller;

  const MultiViewProtoStack({Key? key, required this.controller})
      : super(key: key);

  @override
  State<MultiViewProtoStack> createState() => _MultiViewProtoStackState();
}

class _MultiViewProtoStackState extends State<MultiViewProtoStack> {
  final List<Worker> _workers = [];

  DesktopTabController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _workers.add(ever(controller.state, (_) => _syncAudio()));
    _workers.add(ever(MultiViewProto.gridOn, (_) => _syncAudio()));
  }

  @override
  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    super.dispose();
  }

  // Audio follows the focused tile through the existing per-session "Mute"
  // toggle. It persists per peer and makes the peer stop sending, so a tile
  // closed while muted stays muted next time.
  void _syncAudio() {
    final tabs = controller.state.value.tabs;
    final selected = controller.state.value.selected;
    final grid = MultiViewProto.isEffective(tabs.length);
    for (var i = 0; i < tabs.length; i++) {
      final page = tabs[i].page;
      if (page is! RemotePage) continue;
      FFI? ffi;
      try {
        ffi = page.ffi;
      } catch (_) {}
      if (ffi == null) continue;
      final key = tabs[i].key;
      final wantMuted = grid && i != selected;
      final muted = bind.sessionGetToggleOptionSync(
              sessionId: ffi.sessionId, arg: 'disable-audio') ==
          true;
      if (wantMuted && !muted) {
        bind.sessionToggleOption(
            sessionId: ffi.sessionId, value: 'disable-audio');
        MultiViewProto.mutedByProto.add(key);
      } else if (!wantMuted &&
          muted &&
          MultiViewProto.mutedByProto.remove(key)) {
        bind.sessionToggleOption(
            sessionId: ffi.sessionId, value: 'disable-audio');
      }
    }
  }

  void _focusTile(int index) {
    if (controller.state.value.selected == index) return;
    // Selection is the focused tile: onSelected moves CUR_SESSION_ID and the
    // window title, and RemotePage only takes keyboard focus when selected.
    controller.jumpTo(index);
    final page = controller.state.value.tabs[index].page;
    if (page is RemotePage) page.protoRequestFocus();
  }

  static Rect _cell(int index, int count, Size size) {
    final w = size.width / 2;
    if (count == 2) return Rect.fromLTWH(index * w, 0, w, size.height);
    final h = size.height / 2;
    return Rect.fromLTWH((index % 2) * w, (index ~/ 2) * h, w, h);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Obx(() {
        final tabs = controller.state.value.tabs;
        final selected = controller.state.value.selected;
        final grid = MultiViewProto.isEffective(tabs.length);
        final maxKey = MultiViewProto.maximizedKey.value;
        final maximized = grid && tabs.any((t) => t.key == maxKey);
        final full = Offset.zero & constraints.biggest;
        final rects = <String, Rect>{};
        final children = <Widget>[];
        for (var i = 0; i < tabs.length; i++) {
          final tab = tabs[i];
          final isFocused = i == selected;
          Rect rect = full;
          bool visible = isFocused;
          if (grid) {
            if (maximized) {
              visible = tab.key == maxKey;
            } else {
              rect = _cell(i, tabs.length, constraints.biggest);
              visible = true;
              rects[tab.key] = rect;
            }
          }
          children.add(Positioned.fromRect(
            key: ValueKey(tab.key),
            rect: rect,
            child: Offstage(
              offstage: !visible,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _focusTile(i),
                child: Stack(children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      // A tile you are not in gets no hover or clicks: the
                      // first click only focuses it.
                      ignoring: grid && !isFocused,
                      child: tab.page,
                    ),
                  ),
                  if (grid) ..._tileChrome(i, tab.key, isFocused, maximized),
                ]),
              ),
            ),
          ));
        }
        MultiViewProto.setTileRects(rects);
        return Stack(children: children);
      }),
    );
  }

  List<Widget> _tileChrome(
      int index, String key, bool isFocused, bool maximized) {
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: isFocused ? MyTheme.accent : Colors.black54,
                width: isFocused ? 3 : 1,
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: 8,
        bottom: 8,
        child: GestureDetector(
          onTap: () {
            MultiViewProto.maximizedKey.value = maximized ? null : key;
            _focusTile(index);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(
                DesktopTab.tablabelGetter(key).value,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(width: 6),
              Icon(
                maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                size: 16,
                color: Colors.white,
              ),
            ]),
          ),
        ),
      ),
    ];
  }
}

/// Tab bar button that switches the multi-view on and off.
class MultiViewProtoToggle extends StatelessWidget {
  final DesktopTabController controller;

  const MultiViewProtoToggle({Key? key, required this.controller})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final count = controller.state.value.tabs.length;
      final on = MultiViewProto.gridOn.value;
      final enabled = count <= 4;
      return Tooltip(
        message: enabled
            ? 'Multi-view (prototype)'
            : 'Multi-view (prototype): at most 4 tabs',
        child: InkWell(
          onTap: enabled
              ? () {
                  MultiViewProto.maximizedKey.value = null;
                  MultiViewProto.gridOn.toggle();
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              on ? Icons.grid_view_sharp : Icons.grid_view_outlined,
              size: 18,
              color: !enabled
                  ? Colors.grey
                  : on
                      ? MyTheme.accent
                      : null,
            ),
          ),
        ),
      );
    });
  }
}
