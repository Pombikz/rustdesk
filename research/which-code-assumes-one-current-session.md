# Which code assumes one current session per window?

Research ticket for the Windows Flutter desktop **multi-view** (up to 4 remote
sessions tiled 2x2 in one remote window, exactly one *focused tile* gets local
input) and phase 2 **input broadcast** (a fixed *leader* tile's keyboard and
mouse copied to *follower* tiles). Controller side only, no protocol change.

All references are to this repo at commit `4d37f00af` (master). Paths are from
the repo root. "Sev (a)" is the impact on a 2x2 multi-view with one focused
tile; "Sev (b)" is the impact on input broadcast.

Severity scale:

* **High**: wrong or broken behaviour unless changed; blocks the feature.
* **Medium**: works by accident or partially; needs a targeted change or a
  deliberate decision.
* **Low**: per-window semantics that are acceptable, or cosmetic.
* **None**: already per session / not on the Windows path.

## Background facts the rest depends on

* Each remote **window** is its own Flutter engine and Dart isolate, so Dart
  statics and `stateGlobal` are per window, not per process
  (`flutter/lib/models/input_model.dart:347-350`, `src/keyboard.rs:90-92`).
  Rust statics are per **process** (shared by every window).
* Each `RemotePage` builds its own `FFI`, whose `sessionId` is a fresh UUID per
  page on desktop (`flutter/lib/models/model.dart:4068-4069`,
  `flutter/lib/desktop/pages/remote_page.dart:150`). So `SessionID` is per
  tab/tile; a future tile gets a distinct id for free.
* Rust keeps one `Session` per `(peer_id, conn_type)` in `SESSIONS`
  (`src/flutter.rs:2045`), with one `SessionHandler` per UI `SessionID`
  (`src/flutter.rs:254-256`). Two UI sessions for the same peer share one
  connection, and `is_multi_ui_session()` then disables per-UI display
  switching (`src/flutter.rs:978-985`, `src/flutter.rs:1405-1418`).
* On Windows the default input source is **Input source 1** (rdev low-level
  hook) (`src/keyboard.rs:1611-1617`). With it, Flutter key events are
  swallowed and never forwarded (`flutter/lib/models/input_model.dart:758-761`);
  every keystroke reaches the peer through the process-wide rdev grab loop,
  which has no session context and routes via `CUR_SESSION_ID`. With
  **Input source 2** (Flutter), keys go through `process_event_with_session`
  with an explicit `SessionID` (`src/ui_session_interface.rs:922-1003`,
  `src/keyboard.rs:367-402`).
* Today exactly one page per window is visible: `DesktopTab` renders a
  `PageView` with `NeverScrollableScrollPhysics`
  (`flutter/lib/desktop/widgets/tabbar_widget.dart:556-560`), and the hidden
  pages stay alive through `AutomaticKeepAliveClientMixin`
  (`flutter/lib/desktop/pages/remote_page.dart:1017-1018`).

## 1. Rust: the process-wide "current session"

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 1.1 | `CUR_SESSION_ID: RwLock<SessionID>` "For desktop only" (`src/flutter.rs:54`); getters `get_cur_session_id` / `get_cur_peer_id` / `get_cur_session` (`src/flutter.rs:1664-1671`, `src/flutter.rs:1962-1965`). | One process-wide slot. Last writer wins across **all** windows. | Medium | High |
| 1.2 | `set_cur_session_id` (`src/flutter.rs:1673-1679`) also moves shortcut "released modifiers" from old to new session (`src/keyboard/shortcuts.rs:455-464`). FFI wrapper `set_cur_session_id` / `set_cur_session_id_` (`src/flutter_ffi.rs:2419-2429`) also refreshes the Windows key-name mode (`update_grab_get_key_name`). | Called from Dart on tab select (`flutter/lib/desktop/pages/remote_tab_page.dart:68-73`), on every `InputModel.enterOrLeave(true)` (`flutter/lib/models/input_model.dart:1479-1481`) and inside `session_enter_or_leave(enter=true)` (`src/flutter_ffi.rs:665-666`). | Medium: works if it is only ever written for the focused tile. Must stop being written by tab `onSelected` for non-focused tiles, and by a newly added tile's `initState` (`remote_page.dart:222-225` calls `onSelected`). | High: broadcast needs N targets, not one. |
| 1.3 | Windows rdev grab loop `start_grab_loop` (`src/keyboard.rs:666-731`): when `KEYBOARD_HOOKED`, calls `client::process_event(&get_keyboard_mode(), &event, None)` (`src/keyboard.rs:684-685`). | All hooked keystrokes in the process go to one session. | Low: correct as long as `CUR_SESSION_ID` is the focused tile. | High: the single hook-out point; broadcast must fan out here or below. |
| 1.4 | `client::process_event` (`src/keyboard.rs:324-365`): shortcut dispatch with `session_id = None` resolves to `get_cur_session_id()` (`src/keyboard/shortcuts.rs:486-494`); then `get_peer_platform()` and `send_key_event()`. | Shortcut, encoding and send all target the current session. | Low | High |
| 1.5 | `get_keyboard_mode()` (`src/keyboard.rs:525-536`), `send_key_event()` (`src/keyboard.rs:1051-1061`), `get_peer_platform()` (`src/keyboard.rs:1063-1073`). Fallbacks: `"legacy"` mode, `"Windows"` platform. | Keyboard mode (map/translate/legacy) and peer OS are read from the current session; the encoded `KeyEvent` depends on both (`event_to_key_events`, `src/keyboard.rs:997-1049`). | Low | High: followers may have a different peer OS or keyboard mode, so the leader's encoded `KeyEvent` cannot just be re-sent; encoding must be per follower. |
| 1.6 | `MODIFIERS_STATE` and `TO_RELEASE` are process-global (`src/keyboard.rs:67-81`), updated inside `event_to_key_events` (`src/keyboard.rs:1005-1015`, `update_modifiers_state` at `src/keyboard.rs:980-995`). `is_long_press` (`src/keyboard.rs:771-784`) drops a modifier press if `MODIFIERS_STATE` already says it is down. | One physical keyboard state, one "keys to release" list. | Low | **High**: calling `process_event` once per follower makes the 2nd..Nth call see the modifier already down and drop the press as a "long press" (`src/keyboard.rs:357-359` runs before `event_to_key_events`). Shift/Ctrl/Alt would only reach the first session. |
| 1.7 | `release_remote_keys` / `release_remote_keys_for_events` (`src/keyboard.rs:786-814`) send key-ups through `client::process_event`, i.e. to the current session; also checks `get_peer_platform()` (`src/keyboard.rs:794`). Called on grab `Wait` (`src/keyboard.rs:290-322`). | Stuck-key cleanup goes to one session. | Medium: on tile switch, if the new tile's `Run` arrives before the old tile's `Wait`, the old `Wait` is ignored (`src/keyboard.rs:222-230`) and its held keys stay in `TO_RELEASE` (same race exists between tabs today). | High: followers never get their key-ups on focus loss; held keys stick on followers. |
| 1.8 | Shortcut state: `FIRED_KEYS` is physical/process-wide; `RELEASED_MODIFIERS` keyed by session; `release_modifier_on_leave` uses `get_cur_session_id()` (`src/keyboard/shortcuts.rs:355-378`, `src/keyboard/shortcuts.rs:425-439`). | A fired shortcut consumes the key and its release for every session. | Low | Medium: shortcuts must run only for the leader; a per-follower `try_dispatch` call would be consumed by `FIRED_KEYS` (`src/keyboard/shortcuts.rs:509-514`) or fire actions on followers. |
| 1.9 | Relative-mouse exit chord in the grab loop: `RELATIVE_MOUSE_MODE_ACTIVE` is one global bool (`src/keyboard.rs:50`, set from any session's marker at `src/flutter_ffi.rs:1972` / `src/flutter_ffi.rs:2020`); `can_exit_relative_mouse_mode_from_grab_loop` checks `get_cur_session()` (`src/keyboard.rs:599-622`); `notify_exit_relative_mouse_mode` pushes to `get_cur_session_id()` (`src/keyboard.rs:582-587`). | Exit chord goes to the current session. | Low (only the focused tile can be in relative mode in practice) | Low |
| 1.10 | Windows file-clipboard (cliprdr) `FormatList` from a peer is ignored unless the session's `client_conn_id` matches `get_cur_peer_id()` (`src/client/io_loop.rs:2617-2623`). | Only the current peer may announce remote files. | Low: correct for the focused tile. Text clipboard is already broadcast to all sessions (`src/client.rs:1917-1921`, `src/client.rs:2104-2108`). | None (clipboard is out of scope for broadcast). |

## 2. Rust: grab ownership (Input source 1)

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 2.1 | `GRAB_STATE.owner: Option<u128>` (`src/keyboard.rs:100-117`); `change_grab_status` (`src/keyboard.rs:160-322`). `Run` sets owner and `KEYBOARD_HOOKED=true`; a `Wait` from a non-owner is ignored; `Wait` from the owner clears the hook and releases keys. | One grab owner per process. Ownership is keyed by the per-UI `SessionID` (`src/flutter_ffi.rs:661-664`), so tiles get distinct owners. | Low: one focused tile = one owner fits exactly. | Medium: the leader stays the owner; followers must not acquire the grab. Fine if broadcast fans out after the hook. |
| 2.2 | `session_enter_or_leave` (`src/flutter_ffi.rs:658-681`): on enter it sets `CUR_SESSION_ID` **and** `Run`; on leave `Wait`. `change_input_source` re-enters the given session (`src/keyboard.rs:1642-1662`). | Couples "current session" and "grab owner"; one call per focus change. | Low | Low |
| 2.3 | `Session::enter/leave` keyed by `lc.session_id` (`src/ui_session_interface.rs:879-889`). | Legacy (no Flutter caller found). | None | None |

## 3. Rust: mouse path

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 3.1 | `Session::send_mouse` merges the global `MODIFIERS_STATE` into every mouse event (`src/ui_session_interface.rs:1270-1273`, `src/keyboard.rs:402-425`) and, on Windows, ORs in the OS Win-key state (`src/ui_session_interface.rs:1250-1256`, `src/platform/windows.rs:2364-2366`). | A modifier held for any session is applied to mouse events of every session. | Low: only the hovered tile receives pointer events. | Low, even helpful: followers get the leader's modifiers for free. |
| 3.2 | `session_send_mouse` takes a `session_id` (`src/flutter_ffi.rs:1958`) and absolute remote coordinates computed in Dart per session. | Per session. | None | Medium: coordinates are in the leader's remote display space; followers with other resolutions/display origins need their own mapping (relative moves `move_relative` need none). |

## 4. Dart: focus, enter/leave and the selected tab (`remote_page.dart`)

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 4.1 | `_isSelectedTab` (`flutter/lib/desktop/pages/remote_page.dart:279-287`) and `_windowsCanFocusRemoteInput => _isSelectedTab && !middleBlocked` (`remote_page.dart:291-292`). | A page may only take keyboard focus on Windows if it is the selected tab. | **High**: in a 2x2 grid three visible tiles are not "selected" and could never take focus; must become "is the focused tile". | Medium: followers must never take focus. |
| 4.2 | Windows `onFocusChange` of the per-page `RawKeyFocusScope` drives `InputModel.enterOrLeave` (`remote_page.dart:736-757`), which calls `sessionEnterOrLeave` and `setCurSessionId` (`flutter/lib/models/input_model.dart:1455-1482`). | Flutter has one primary focus per window, so exactly one page is "entered". | Low: per-tile `FocusNode` already gives "one focused tile". | Medium: only the leader is ever entered; followers' `enterOrLeave` is never called, so their per-InputModel modifier/release state is never reset. |
| 4.3 | `enterView` on Windows requests focus on **pointer enter** (`remote_page.dart:847-880`, focus at `866-873`); `onWindowFocus` refocuses if the cursor is over the image (`remote_page.dart:534-541`); pointer down requests focus (`remote_page.dart:926-951`). | Hovering the image gives it the keyboard (focus follows mouse). | **High** (decision): in a grid, moving the mouse across tiles would move keyboard focus and `CUR_SESSION_ID`. Needs an explicit hover-vs-click focus policy. | High: hovering a follower would steal input from the leader. |
| 4.4 | `onWindowBlur` / `onWindowFocus` / minimize / fullscreen listeners are per page via `MultiWindowListener` (`remote_page.dart:486-558`, `remote_page.dart:612-647`). Every page in the window gets them and writes `stateGlobal.isFocused` (`remote_page.dart:500`, `remote_page.dart:519`). | Each kept-alive page reacts to window events. | Low: idempotent writes; relative-mouse handling only acts if that page's mode is on. | Low |
| 4.5 | File-level globals `_firstEnterImage` (`remote_page.dart:31`) and `closeSessionOnDispose` keyed by peer id (`remote_page.dart:34`, read at `652`, set at `flutter/lib/desktop/pages/remote_tab_page.dart:527`). | Shared by all pages in the window. | Low (`_firstEnterImage` is only used by commented-out code and a cursor path) | None |
| 4.6 | `bind.hostStopSystemKeyPropagate` toggled by the image `MouseRegion` enter/exit and on dispose (`remote_page.dart:960-966`, `remote_page.dart:668`), backed by one process-wide Windows flag (`src/flutter_ffi.rs:111-114`). | Last writer wins. | Low: exit of tile A then enter of tile B leaves the right value; a late exit could flip it. | Low |
| 4.7 | macOS-only latches (`remote_page.dart:92-110`, `_syncMacOSKeyboardGrab` at `340-372`). | Not on the Windows path. | None | None |

## 5. Dart: canvas geometry assumes the page fills the window

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 5.1 | `CanvasModel.getSize()` uses the whole Flutter view: `MediaQueryData.fromView(ui.window).size` minus static window chrome (`flutter/lib/models/model.dart:2338-2343`). `updateViewStyle` uses it for scale and offsets (`model.dart:2382-2420`). `_ViewStyleUpdater` passes the real layout size only to `InputModel.updateImageWidgetSize`, not to the canvas (`remote_page.dart:1068-1070`). `CursorModel.getVisibleRect` / `getCanvasOffsetToCenterCursor` also use `getSize()` (`model.dart:3239-3260`). | Scale-adaptive scaling, centering and scroll math all assume one page as large as the window. | **High**: each tile would be scaled and centered for the full window and paint/hit-test wrongly. `getSize()` must come from the tile's constraints. | Medium: broadcast coordinate translation depends on correct per-tile canvas. |
| 5.2 | Static `CanvasModel.leftToEdge/rightToEdge/topToEdge/bottomToEdge` = window border + tab-bar height (`model.dart:2328-2336`). Pointer mapping uses `event.position` (window-global) "because their pointer mapping is window-based" (`flutter/lib/models/input_model.dart:1935-1940`) and subtracts only these statics (`input_model.dart:2275-2276`); canvas-relative math follows in `_handlePointerDevicePos` (`input_model.dart:2329-2387`). | Assumes the canvas origin is the window's top-left below the tab bar. | **High**: tiles at x>0 or y>0 get offset coordinates; must use the tile's own origin (e.g. `localPosition`). | High: same mapping is needed per follower. |
| 5.3 | Toolbar "Adjust Window" sizes the OS window to one session's display using the same statics (`flutter/lib/desktop/widgets/remote_toolbar.dart:1498-1560`). | Window = one session. | Medium: meaningless in a grid; hide or redefine. | None |
| 5.4 | Cross-window cursor move (`kWindowEventRemoteWindowCoords`) answers with the selected tab's canvas (`flutter/lib/desktop/pages/remote_tab_page.dart:530-553`); consumer at `input_model.dart:1950-1966`, `2255-2273`. | Assumes the selected tab is the window's only canvas. | Low (only used for multi-window same-peer display mode) | None |

## 6. Dart: relative mouse mode (`relative_mouse_model.dart`)

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 6.1 | Clip rect from the pointer region: `_pointerRegionTopLeftGlobal = e.position - e.localPosition` (`flutter/lib/models/relative_mouse_model.dart:215-217`) plus `_imageWidgetSize` from the layout (`relative_mouse_model.dart:209-213`); `_applyCursorClipForFrame` clips to that region (`relative_mouse_model.dart:913-968`). Deltas use `localPosition` (`relative_mouse_model.dart:528-556`). | Already region-aware, so it mostly works for a tile. | Low | Low: `move_relative` deltas need no coordinate mapping, so broadcast of relative moves is easy. |
| 6.2 | Fallbacks assume the window: center = window frame center when the region is unknown (`relative_mouse_model.dart:866-873`), clip to the whole client area (`relative_mouse_model.dart:955-960`); the client-area offset is a frame-vs-view heuristic using `views.firstOrNull` (`relative_mouse_model.dart:804-865`). `ClipCursor` is one OS-wide rect (`src/flutter_ffi.rs:1373-1393`). | Window-sized fallback; single clip. | Low: fine with one focused tile; fallbacks could clip to the whole window. | Low |
| 6.3 | Toolbar is hidden while relative mode is on (`remote_page.dart:783-792`); tab-bar hint reads `stateGlobal.relativeMouseModeState[peerId]` for the **selected tab** (`remote_tab_page.dart:571-596`, map at `flutter/lib/models/state_model.dart:32-35`, written at `input_model.dart:524-530`). | Hint shows the selected tab only; keyed by peer id. | Low (cosmetic) | None |

## 7. Audio

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 7.1 | Each session's `io_loop` starts its own audio thread (`src/client/io_loop.rs:133`, `src/client.rs:4134-4161`), which opens the **default output device** (`src/client.rs:2376-2380`). | Every connected session plays at once; the OS mixes them. No "current session" concept for audio. | Medium: 4 tiles = 4 overlapping audio streams. Needs a policy (e.g. audio follows focused tile). | None |
| 7.2 | Mute is the per-session toggle `disable-audio` (`flutter/lib/common/widgets/toolbar.dart:1072-1084`): client drops frames (`src/client/io_loop.rs:2290-2295`), sends an `OptionMessage` so the peer stops sending (`src/client.rs:3224-3231`, server `src/server/connection.rs:4980-4983`), and **persists** it to the peer config (`src/client.rs:3334-3336`). | Per-session mute already exists, but it is a toggle, it is remembered for the next connection to that peer, and it is visible to the peer. | Medium: muting non-focused tiles is possible today with `sessionToggleOption`, but it would persist and must be undone on exit; a non-persistent local mute (drop frames only) would be a new hook. | None |

## 8. Window-level toolbar, tab bar and shortcuts

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 8.1 | `DesktopTabState.selected` / `selectedTabInfo` (`flutter/lib/desktop/widgets/tabbar_widget.dart:61-68`); `jumpTo` sets `selected`, scrolls the `PageController` and calls `onSelected` (`tabbar_widget.dart:152-180`); `PageView` shows one page (`tabbar_widget.dart:556-585`). | The whole tab model is "one selected page". | High: multi-view needs a grid builder in place of (or beside) the `PageView`, and a notion of focused tile separate from `selected`. | Low |
| 8.2 | `onSelected` sets `CUR_SESSION_ID` and the **window title** (`flutter/lib/desktop/pages/remote_tab_page.dart:68-77`). | Title = selected peer. | Medium (title should follow focused tile or show the grid) | None |
| 8.3 | Tab right-click menu, close and "move to new window" resolve by tab key (`remote_tab_page.dart:200-215`, `remote_tab_page.dart:245-345`); window close button closes all (`remote_tab_page.dart:392-418`). | Per tab key. | Low | None |
| 8.4 | Each `RemotePage` builds its own `RemoteToolbar` and `ToolbarState` (`remote_page.dart:712-729`, `remote_page.dart:783-792`; created at `remote_tab_page.dart:98`). Window-level actions inside it: fullscreen (`remote_toolbar.dart:486-491`, `stateGlobal.setFullscreen`), minimize (`remote_toolbar.dart:503-504`), Adjust Window (5.3), input-source switch (`remote_toolbar.dart:2710-2722`). | One toolbar per page, but it drives the window. | Medium: four toolbars would appear in a grid; show only the focused tile's toolbar or a single window toolbar. | Low |
| 8.5 | Session shortcuts are registered per `FFI` (`flutter/lib/models/shortcut_model.dart:24-46`, `shortcut_model.dart:296-301`) and dispatched by session id from Rust (`src/keyboard/shortcuts.rs:556-565`). Switch-tab next/prev and close-tab use the window's `tabController` and the session's own peer id (`shortcut_model.dart:405-438`); fullscreen toggles `stateGlobal` (`shortcut_model.dart:317-322`). | Shortcut runs for the session that got the key, i.e. the current one. | Medium: "switch tab" semantics in a grid (cycle focus between tiles?) need a decision. | Medium: shortcuts must fire for the leader only, never on followers. |
| 8.6 | `stateGlobal` (`flutter/lib/models/state_model.dart:10-140`): `fullscreen`, `isFocused`, `showTabBar`, `windowBorderWidth`, input source cache (`state_model.dart:123-133`), `isInputSourceFlutter` (`flutter/lib/common.dart:3490`). Per isolate = per window. | Window attributes. | Low: these really are per window. | Low |

## 9. State keyed by peer id

| # | Assumption (file:line) | What it does today | Sev (a) | Sev (b) |
|---|---|---|---|---|
| 9.1 | `Get.put<FFI>(_ffi, tag: widget.id)` / `Get.delete<FFI>(tag: widget.id)` (`remote_page.dart:159`, `remote_page.dart:698`); lookup `ffi(tag)` (`flutter/lib/common.dart:1588-1591`). | One FFI per peer id per isolate. | Low if the grid forbids the same peer twice; High otherwise (second tile overwrites the first's registration). | None |
| 9.2 | Shared Rx states keyed by peer id: `initSharedStates` / `removeSharedStates` (`flutter/lib/common/shared_state.dart:342-368`), e.g. `CurrentDisplayState`, `KeyboardEnabledState`, `ShowRemoteCursorState`, `PrivacyModeState`, `ConnectionTypeState`, `FingerprintState` (`shared_state.dart:8-245`); `UnreadChatCountState`; `stateGlobal.relativeMouseModeState` and `_lastResolutionGroupValues` (`state_model.dart:35-58`). | Per peer, per window. | Low with distinct peers per tile. | None |
| 9.3 | Tab key = peer id; `DesktopTabController.add` dedupes on key and jumps to the existing tab (`tabbar_widget.dart:109-129`). In Rust a second UI session for the same peer shares one connection and becomes "multi UI session" (`src/flutter.rs:978-985`). | Same peer cannot appear twice in one window today. | Low: keep that rule for tiles. | None |
| 9.4 | Linux-only static `_activeSideButtonModel` (`input_model.dart:340-366`). | Not Windows. | None | None |

## What matters most

1. **`CUR_SESSION_ID` is the only keyboard router for Windows' default input
   source.** It is process-wide and written by tab select, page init and every
   `enterOrLeave(true)` (1.1-1.5). For (a) it must be written only for the
   focused tile. For (b) it is the wrong shape: broadcast has to fan out after
   the rdev hook.
2. **Global `MODIFIERS_STATE` / `TO_RELEASE` break naive fan-out.**
   `is_long_press` drops modifier presses for every session after the first,
   and stuck-key release only reaches the current session (1.6, 1.7).
   Followers also need per-follower encoding, because peer OS and keyboard
   mode differ (1.5).
3. **Focus is gated on "selected tab" and follows the mouse on Windows.**
   `_windowsCanFocusRemoteInput` and focus-on-`PointerEnter` (4.1, 4.3) must be
   replaced by an explicit focused-tile rule (click-to-focus is the safe
   default for a grid).
4. **Canvas geometry assumes one page fills the window.** `getSize()` reads
   `ui.window`, and pointer mapping subtracts static window edges from global
   positions (5.1, 5.2). These must be per tile before a grid can render or
   hit-test correctly.
5. **The tab model is "one selected page" with a `PageView`** (8.1, 8.2, 8.4).
   Toolbar, title and tab shortcuts all key off `selected`.
6. **Audio already plays from every session at once.** Per-session mute
   exists, but it is persistent and visible to the peer (7.1, 7.2).
7. **Already fine:** per-tile `SessionID`, grab ownership keyed by `SessionID`
   (2.1), relative-mouse clip math (6.1), text clipboard broadcast (1.10) and
   peer-keyed state, as long as each peer appears in at most one tile (9.x).
