import 'dart:ui';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:get/get.dart';

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

  /// Cell of each tile inside the tab content area, by tab key. Empty when
  /// a single tile fills the area, so master's whole-window math runs.
  static final Map<String, Rect> _tileRects = {};

  static void init() {
    enabled = isWindows && mainGetLocalBoolOptionSync(kOptionAllowMultiView);
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
}
