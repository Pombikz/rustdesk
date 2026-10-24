import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';

/// Multi-view state of a remote window. Each remote window runs in its own
/// isolate, so static state here is per window.
class MultiViewModel {
  /// Whether this window renders its tabs through [MultiViewStack].
  ///
  /// Read once when the window is built, never live: moving a page between
  /// the [PageView] and the stack remounts it, and that closes its session.
  static bool enabled = false;

  static void init() {
    enabled = isWindows && mainGetLocalBoolOptionSync(kOptionAllowMultiView);
  }
}
