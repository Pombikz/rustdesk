import 'dart:ui';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:get/get.dart';

enum BroadcastState { off, on, paused }

/// What the input broadcast snapshot needs to know about one tile.
class BroadcastTile {
  final String key;
  final bool connected;
  final bool viewOnly;

  const BroadcastTile(this.key,
      {required this.connected, required this.viewOnly});
}

/// The leader and the followers that receive its input, by tab key. Both
/// are empty unless [state] is on.
class BroadcastSnapshot {
  final BroadcastState state;
  final String? leader;
  final List<String> followers;

  const BroadcastSnapshot(this.state, {this.leader, this.followers = const []});
}

/// Multi-view state of a remote window. Each remote window runs in its own
/// isolate, so static state here is per window.
class MultiViewModel {
  /// Whether this window renders its tabs through [MultiViewStack].
  ///
  /// Read once when the window is built, never live: moving a page between
  /// the [PageView] and the stack remounts it, and that closes its session.
  static bool enabled = false;

  static const int maxTiles = 4;

  /// The grid button's state. Not saved: every window starts with it off.
  static final gridOn = false.obs;

  /// Whether the focused tile fills the window while the grid is on.
  static final maximized = false.obs;

  /// Cell of each tile inside the tab content area, by tab key. Empty when
  /// a single tile fills the area (one tab, or a maximised tile), so
  /// master's whole-window math runs.
  static final Map<String, Rect> _tileRects = {};

  static void init() {
    enabled = isWindows && mainGetLocalBoolOptionSync(kOptionAllowMultiView);
  }

  static void toggleGrid() {
    maximized.value = false;
    broadcastOn.value = false;
    gridOn.toggle();
  }

  /// The flag is kept with more than [maxTiles] tabs, but the grid only
  /// shows again once the tab count is back within it.
  static bool isGrid(int tabCount) =>
      enabled && gridOn.value && tabCount <= maxTiles;

  /// Cells for [count] tiles filling [size], in tab order: 1 fills it, 2 sit
  /// side by side, 3 and 4 take the quadrants. Empty when they don't fit.
  static List<Rect> layout(int count, Size size) {
    if (count < 1 || count > maxTiles) return [];
    if (count == 1) return [Offset.zero & size];
    final w = size.width / 2;
    if (count == 2) {
      return [
        Rect.fromLTWH(0, 0, w, size.height),
        Rect.fromLTWH(w, 0, w, size.height),
      ];
    }
    final h = size.height / 2;
    return [
      for (var i = 0; i < count; i++)
        Rect.fromLTWH((i % 2) * w, (i ~/ 2) * h, w, h),
    ];
  }

  static Rect? tileRect(String? key) => key == null ? null : _tileRects[key];

  static void setTileRects(Map<String, Rect> rects) {
    _tileRects
      ..clear()
      ..addAll(rects);
  }

  /// Tab key of the leader. Kept across grid toggles, never saved.
  static final leader = RxnString();

  /// Tab keys whose follow switch is off. Follow is on by default.
  static final notFollowing = <String>{}.obs;

  /// The broadcast button's state. Every window and every grid starts off.
  static final broadcastOn = false.obs;

  static void makeLeader(String key) {
    final old = leader.value;
    if (old != null) notFollowing.remove(old);
    leader.value = key;
  }

  static void toggleFollow(String key) {
    if (!notFollowing.remove(key)) notFollowing.add(key);
  }

  /// False when no leader is marked, so there is nothing to turn on.
  static bool toggleBroadcast() {
    if (leader.value == null) return false;
    broadcastOn.toggle();
    return true;
  }

  /// A closed or moved leader tab turns broadcast off, as does a tab count
  /// the grid can't show. A closed tab forgets its follow switch, so the
  /// same peer opened again joins following.
  static void tabsChanged(List<String> keys) {
    // Selection changes come through here too; refresh only on a change.
    final closed = notFollowing.where((key) => !keys.contains(key)).toList();
    if (closed.isNotEmpty) notFollowing.removeAll(closed);
    if (leader.value != null && !keys.contains(leader.value)) {
      leader.value = null;
      broadcastOn.value = false;
    }
    if (keys.length > maxTiles) broadcastOn.value = false;
  }

  /// Broadcast runs only while it is on and the leader is the focused,
  /// connected tile; on otherwise is paused. The followers are every other
  /// connected, following tile that isn't view-only.
  static BroadcastSnapshot broadcastSnapshot({
    required bool grid,
    required bool on,
    required String? leader,
    required String? focused,
    required Set<String> notFollowing,
    required List<BroadcastTile> tiles,
  }) {
    final leaderTile = tiles.firstWhereOrNull((t) => t.key == leader);
    if (!grid || !on || leaderTile == null) {
      return const BroadcastSnapshot(BroadcastState.off);
    }
    if (focused != leader || !leaderTile.connected) {
      return const BroadcastSnapshot(BroadcastState.paused);
    }
    return BroadcastSnapshot(BroadcastState.on, leader: leader, followers: [
      for (final t in tiles)
        if (t.key != leader &&
            !notFollowing.contains(t.key) &&
            t.connected &&
            !t.viewOnly)
          t.key,
    ]);
  }
}
