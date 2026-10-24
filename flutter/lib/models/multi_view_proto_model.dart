// PROTOTYPE, never merge. Throwaway 2x2 multi-view for wayfinder ticket
// "Does a 2x2 grid of live sessions work in the remote window?"
// (.scratch/multi-view/issues/04-*.md). Lives only on prototype/multi-view-grid.

import 'dart:ui';

import 'package:get/get.dart';

class MultiViewProto {
  static final gridOn = false.obs;

  /// Tab key of the tile shown alone while the grid is on.
  static final maximizedKey = RxnString();

  /// Peers whose audio this prototype muted, so only those get unmuted again.
  static final Set<String> mutedByProto = {};

  /// Cell of each tile inside the tab content area, written on every grid
  /// build. Empty when the grid is off or a tile is maximized, so the
  /// existing whole-window canvas math runs unchanged.
  static final Map<String, Rect> _tileRects = {};

  static bool isEffective(int tabCount) =>
      gridOn.value && tabCount >= 2 && tabCount <= 4;

  static Rect? tileRect(String? peerId) =>
      peerId == null ? null : _tileRects[peerId];

  static void setTileRects(Map<String, Rect> rects) {
    _tileRects
      ..clear()
      ..addAll(rects);
  }
}
