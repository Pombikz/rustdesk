# How does RustDesk send mouse movement, absolute and relative?

Research ticket for the "input broadcast" (multiboxing) design: a Windows Flutter
desktop controller with up to 4 sessions, where a leader's mouse is copied to
followers. Controller-side only, stock peers, no protocol change.

Code references are to this repo at `4d37f00af` (master, Oct 2026). Release-tag
notes come from `git show <tag>:<path>`. "MS docs" are the Microsoft Learn pages
listed at the end.

## TL;DR

- A stock peer takes one mouse message, `MouseEvent { mask, x, y, modifiers }`.
  `mask & 7` is the event type: 0 move (absolute), 1 down, 2 up, 3 wheel,
  4 trackpad, 5 relative move. `mask >> 3` is a single button: 1 left, 2 right,
  4 middle, 8 back, 16 forward.
- In normal mode the controller sends **absolute peer pixels**: coordinates in
  the peer's virtual desktop, in the peer's physical pixels. The controller does
  all the scaling, so a peer with a different resolution is handled entirely on
  the controller side. A Windows peer injects these with
  `SendInput(MOUSEEVENTF_MOVE | ABSOLUTE | VIRTUALDESK)`.
- In relative mode the controller sends **integer deltas** (type 5) in controller
  Flutter logical pixels. These are not scaled to the peer's resolution. A
  Windows peer injects them with `SendInput(MOUSEEVENTF_MOVE)` and no ABSOLUTE
  flag, so Windows pointer ballistics apply to the cursor. A peer must be 1.4.5
  or newer to understand type 5; older peers drop it silently.
- Raw-input (WM_INPUT) games: a relative injection should arrive as a relative
  raw delta. An absolute injection should arrive as `MOUSE_MOVE_ABSOLUTE`
  normalized 0..65535 data, which games that read `lLastX` as a delta handle
  badly. This is inferred from the documented structs, not stated by Microsoft
  (see section 3), so verify it empirically.
- Coalescing: normal-mode moves are not throttled anywhere in RustDesk. Every
  Flutter hover/move event becomes one network message and one `SendInput` on
  the peer. Relative mode batches deltas on a 16 ms timer on Windows and Linux
  controllers.
- Out-of-range positions: the controller drops a move more than 5 px outside
  the display rect. A 1.5.0+ Windows peer clamps whatever it receives to the
  virtual desktop. Before 1.5.0 the peer passed unclamped (and possibly
  overflowing) normalized values to `SendInput`.

## 1. The wire format

### Protocol message

`libs/base/protos/message.proto:192-197`:

```proto
message MouseEvent {
  int32 mask = 1;
  sint32 x = 2;
  sint32 y = 3;
  repeated ControlKey modifiers = 4;
}
```

The message is carried in `Message.union` as `mouse_event`. There is also
`PointerDeviceEvent` (`message.proto:185-190`), but it only carries touch
gestures: pan start/update/end and scale. On a Windows peer only
`ScaleUpdate` does anything; it becomes Ctrl+wheel
(`src/server/input_service.rs:1233-1251`, `handle_scale` at `:1519`). It is not
a mouse path.

### Mask layout

`src/common.rs:66-92` (`crate::input`):

| Bits | Constant | Value | Meaning of `x`, `y` |
|---|---|---|---|
| `mask & 0x7` | `MOUSE_TYPE_MOVE` | 0 | absolute peer pixel position |
| | `MOUSE_TYPE_DOWN` | 1 | ignored by the injector (controller sends 0,0) |
| | `MOUSE_TYPE_UP` | 2 | ignored by the injector (controller sends 0,0) |
| | `MOUSE_TYPE_WHEEL` | 3 | wheel steps (x horizontal, y vertical) |
| | `MOUSE_TYPE_TRACKPAD` | 4 | raw scroll amount |
| | `MOUSE_TYPE_MOVE_RELATIVE` | 5 | delta dx, dy |
| | (reserved) | 6, 7 | ignored |
| `mask >> 3` | `MOUSE_BUTTON_LEFT` | 0x01 | |
| | `MOUSE_BUTTON_RIGHT` | 0x02 | |
| | `MOUSE_BUTTON_WHEEL` | 0x04 | middle button |
| | `MOUSE_BUTTON_BACK` | 0x08 | X1 |
| | `MOUSE_BUTTON_FORWARD` | 0x10 | X2 |

The peer matches the button field with `match buttons { MOUSE_BUTTON_LEFT => ..`
(`input_service.rs:1377-1412`). One event therefore presses or releases
**exactly one** button, and a combined value such as `0x03` does nothing. The
FFI parser can only produce one button per message anyway
(`src/flutter_ffi.rs:2046-2055`).

`modifiers` are applied only on `MOUSE_TYPE_DOWN`. The peer presses any listed
modifier that is not already down, injects the click, then releases what it
pressed (`input_service.rs:1296-1316`, `:1460-1463`).

### Controller send pipeline

1. Dart builds a JSON map of strings, for example
   `{"type":"", "x":"812", "y":"440", "buttons":""}`. An empty type means move.
   It then calls `bind.sessionSendMouse` (`flutter/lib/models/input_model.dart:2223-2237`).
2. `session_send_mouse` (`src/flutter_ffi.rs:1958-2058`) maps the type string
   to a mask (`"down"`, `"up"`, `"wheel"`, `"trackpad"`, `"move_relative"`, and
   anything else to 0, which is move) and maps `buttons` to `<< 3`. It also
   validates the `relative_mouse_mode` enable marker; the disable marker never
   leaves the controller (`:1964-2021`).
3. `Session::send_mouse` (`src/ui_session_interface.rs:1238-1307`) applies
   reverse-wheel and swap-left-right, then calls `client::send_mouse`
   (`src/client.rs:4303-4342`). That function builds the protobuf and calls
   `interface.send(Data::Message(..))`, one network message per call.

## 2. Normal mode: absolute peer pixels

### Where moves come from

`onPointHoverImage` (`input_model.dart:1604-1632`, no button held) and
`onPointMoveImage` (`:1899-1921`, button held) fire for every Flutter pointer
event of kind `mouse` over the remote image. Each one calls
`handleMouse(_getMouseEvent(e, 'mousemove'), canvasPosition)`. On desktop,
`canvasPosition` is simply `event.position`, the window-global logical position
(`:1937-1950`).

`processEventToPeer` (`:2134-2221`) then does the following:

- It runs `_checkPeerControlProtected` (`:2107-2132`). If the peer's local user
  recently moved the mouse (`cursorModel.gotMouseControl == false`), the event
  is dropped until the controller pointer moves more than
  `kMouseControlDistance`.
- For down and up it sets `x = y = '0'` (`:2196-2198`), so clicks carry no
  position. The peer clicks wherever its cursor already is. If no move has been
  sent since the pointer entered the image, a move to the down position is sent
  first (`:2173-2177`).
- For moves it sets `x, y` to the integer result of `handlePointerDevicePos`
  (`:2199-2201`).

### Mapping local position to peer pixels

`handlePointerDevicePos` (`input_model.dart:2239-2311`) and
`_handlePointerDevicePos` (`:2329-2388`) work as follows:

1. Subtract the canvas origin in the window (`CanvasModel.leftToEdge` and
   `topToEdge`).
2. Undo scroll or centering. With `scrollauto`, subtract `canvas.x/y`.
   Otherwise add `imageWidth * scrollX` and remove the centering margins.
3. Divide by `canvas.scale` (`:2365`). This is the only place where a resolution
   difference between the controller's view and the peer is handled. In
   "Original" view style, `scale = 1 / devicePixelRatio` (`flutter/lib/models/model.dart:2431`),
   so one peer pixel equals one controller physical pixel. In fit or custom
   styles, `scale` is the view zoom.
4. Add `rect.left`, `rect.top` (`:2376-2377`). `rect` is `ffiModel.rect`.
5. Pass the result to `getPointInRemoteRect` (`:2390-2438`) for bounds handling
   (section 5).

`ffiModel.rect` is `displaysRect()`, the bounding box of the displays currently
shown (`model.dart:183-211`, set in `updateCurDisplay` at `:786-810`):

- When one display is selected, the rect is that display's `DisplayInfo`:
  `x, y, width, height`.
- In "all displays" mode (`kAllDisplayValue`) it is the union of all peer
  displays (`getCurDisplays`, `model.dart:4578-4590`).
- The values come straight from the peer's `DisplayInfo`
  (`src/server/display_service.rs:868-879`, origin, width and height of each
  monitor). A Windows peer process is per-monitor DPI aware
  (`SetProcessDpiAwareness(2)`, `src/main.rs:27`), so these values are physical
  pixels in the peer's virtual-desktop coordinate space. Origins can be negative.

When the user drags across windows (one RustDesk window per peer display), and
the pointer leaves the current window and enters another remote window of the
same session, `findRemoteCoords` swaps in that window's canvas and rect
(`input_model.dart:2255-2273`).

The number sent is therefore an absolute pixel in the peer's virtual desktop.
The controller already accounts for its own DPI, the view zoom and the display
origin.

### How a Windows peer applies it

The peer runs `connection.rs:3197-3235`, then `input_mouse` pushes the event to
an unbounded `std::sync::mpsc` channel (`connection.rs:554`, `:2429-2447`). A
dedicated input thread (`handle_input`, `:1249-1270`) calls
`input_service::handle_mouse`. On Windows that goes through the portable
service when it is running (`src/server/portable_service.rs:1543-1557`),
otherwise directly to `handle_mouse_simulation_` (`input_service.rs:1288-1464`).

For `MOUSE_TYPE_MOVE` (`input_service.rs:1318-1346`) it calls
`en.mouse_move_to(x, y)`, which is in `libs/enigo/src/win/win_impl.rs:139-163`:

```rust
let (left, top, width, height) = (GetSystemMetrics(SM_XVIRTUALSCREEN), ..SM_YVIRTUALSCREEN,
                                  ..SM_CXVIRTUALSCREEN, ..SM_CYVIRTUALSCREEN);
let dx = to_absolute(x, left, width);   // (x-left)*65535/width, clamped 0..=65535
mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0, dx, dy);
```

`mouse_event` (`win_impl.rs:23-40`) is one `SendInput` of one `INPUT_MOUSE`,
with `dwExtraInfo = ENIGO_INPUT_EXTRA_VALUE (100)`, `time = 0`, and no
`MOUSEEVENTF_MOVE_NOCOALESCE`. MS docs (MOUSEINPUT) say that with ABSOLUTE,
`dx`/`dy` are "normalized absolute coordinates between 0 and 65,535". With
VIRTUALDESK they "map to the entire virtual desktop".

The peer also records `LATEST_PEER_INPUT_CURSOR` (`:1340-1345`) and clears that
connection's relative-mode flag (`:1320`).

Buttons go through `mouse_down` and `mouse_up` (`win_impl.rs:170-225`):
`MOUSEEVENTF_{LEFT,RIGHT,MIDDLE,X}{DOWN,UP}`, with no move component. Wheel
(`input_service.rs:1413-1457`, `win_impl.rs:227-233`) is handled like this:
`x = -evt.x`, `y = evt.y`, both multiplied by `WHEEL_DELTA` (120) unless the type
is trackpad, then sent with `MOUSEEVENTF_WHEEL` or `MOUSEEVENTF_HWHEEL`. The
controller sends one step (±1) per Flutter scroll event, or up to ±3 when the
peer is macOS (`input_model.dart:1975-2022`).

## 3. Relative mouse mode

### Controller side (`flutter/lib/models/relative_mouse_model.dart`)

- The mode is offered only if the peer version is at least
  `kMinVersionForRelativeMouseMode = '1.4.5'` (`flutter/lib/consts.dart:308`,
  `relative_mouse_model.dart:190-205`). It is never offered for Linux peers or
  Wayland controllers. Rust mirrors the version in
  `MIN_VERSION_RELATIVE_MOUSE_MODE` (`src/common.rs:212`).
- On enable, the controller sends a marker: `type: move_relative, x: 0, y: 0,
  relative_mouse_mode: 1` (`:496-500`). The FFI forwards it as a no-op relative
  move (`flutter_ffi.rs:1976-2021`).
- On a Windows controller the OS cursor is confined with `ClipCursor`
  (`bind.mainClipCursor`, `:962-968`, `src/flutter_ffi.rs:1373`) and warped back
  with `SetCursorPos` (`bind.mainSetCursorPosition`, `_recenterMouse`,
  `:723-765`) when it comes within 10% of the image edge (20 to 100 px,
  `:611-659`).
- Deltas come from **successive Flutter pointer positions**:
  `delta = localPosition - _lastPointerLocalPos` (`handleRelativeMouseMove`,
  `:515-554`). The event caused by a recenter is skipped (`:526-531`). These
  values are Flutter logical pixels derived from WM_MOUSEMOVE. They are not raw
  mouse counts: the controller's own pointer ballistics have already been
  applied, and they are not divided by `canvas.scale` or mapped to the peer's
  resolution.
- `RelativeMouseAccumulator` (`flutter/lib/utils/relative_mouse_accumulator.dart`)
  keeps the fractional part, emits integer deltas, and clamps each axis to
  `kMaxRelativeMouseDelta = 10000` (`consts.dart:316`).
- Throttle: deltas are summed into `_pendingDeltaX/Y` and flushed by a one-shot
  16 ms `Timer` (`_throttleInterval`, `:167-171`, `sendRelativeMouseMove`
  `:574-588`, `_flushPendingDelta` `:590-609`). This gives at most about 60
  relative messages per second.
- On a macOS controller, a native host channel delivers deltas from
  `CGAssociateMouseAndMouseCursorPosition` and NSEvent. They are sent unthrottled
  (`:76-87`).
- Buttons in relative mode carry no position (`sendRelativeMouseButton`,
  `:663-680`). The wheel still uses the normal path.

### Peer side

`MOUSE_TYPE_MOVE_RELATIVE` is handled at `input_service.rs:1351-1376`: the peer
clamps dx and dy to ±10000, calls `en.mouse_move_relative(dx, dy)`, and then
reads back `get_cursor_pos()` for tracking. On Windows, `mouse_move_relative`
is `mouse_event(MOUSEEVENTF_MOVE, 0, x, y)` (`win_impl.rs:165-167`). This is a
**true relative injection**: `SendInput` with MOVE and **no** ABSOLUTE flag.

The peer turns off whiteboard and cursor echo while relative mode is active
(`input_service.rs:1271-1283`).

The path predates the mode: the same function already existed in 1.4.6
(`git show 1.4.6:libs/enigo/src/win/win_impl.rs:139-141`). It is also used by
`try_activate_screen` (`connection.rs:6491-6497`). Relative mode itself landed
in `998b75856` (#13928) and is in tags 1.4.5 and later.

Peers older than 1.4.5 decode type 5 with `evt.mask & 0x7` and fall into
`_ => {}`, so the event is dropped silently
(`git show 1.4.4:src/server/input_service.rs:1024-1147`).

### What the peer's OS does with each kind (MS docs)

MOUSEINPUT remarks say this about relative movement:

> "Relative mouse motion is subject to the effects of the mouse speed and the
> two-mouse threshold values."

The system can double, or quadruple, the distance, depending on the peer's
Pointer Speed and "Enhance pointer precision" settings. A relative delta of N
therefore moves the peer's cursor by a ballistics-dependent amount, not N
pixels. Absolute moves are exact.

For raw input, the RAWMOUSE struct has
`usFlags = MOUSE_MOVE_RELATIVE (0) | MOUSE_MOVE_ABSOLUTE (1) | MOUSE_VIRTUAL_DESKTOP (2)`.
For absolute data, `lLastX/lLastY` "contain normalized absolute coordinates
between 0 and 65,535". The RAWMOUSE page also says raw input "is not subject to
the effects of the mouse speed". The High-Definition Mouse Movement article's
sample reads `lLastX/lLastY` as relative without checking `usFlags`. Many games
do the same.

Inference: these docs do not state outright which raw flags a `SendInput`
injection produces. The common model, and the mapping implied by matching flag
sets, is this:

- A relative `SendInput` produces a WM_INPUT with `MOUSE_MOVE_RELATIVE` and
  `lLastX = dx`, the unaccelerated delta. A raw-input game sees exactly the
  delta RustDesk sent, while the visible cursor moves by the accelerated
  amount.
- An absolute `SendInput` (what normal mode produces) produces a WM_INPUT with
  `MOUSE_MOVE_ABSOLUTE | MOUSE_VIRTUAL_DESKTOP` and normalized coordinates. A
  game that treats `lLastX` as a delta sees huge jumps or ignores the event. A
  game that follows the documented sample converts it back to a position. Games
  that read the cursor (WM_MOUSEMOVE or `GetCursorPos`) see both kinds as
  ordinary cursor motion.
- `RAWINPUTHEADER.hDevice` is documented only as "a handle to the device". The
  common observation is that injected input arrives with `hDevice == NULL`.
  Some games and anti-cheat software reject injected input.

**Verify with a spike** (a WM_INPUT logger on a Windows peer) before the design
relies on any of this.

## 4. Rate limiting and coalescing today

| Stage | Normal (absolute) moves | Relative moves |
|---|---|---|
| Flutter controller | None. One message per `PointerHoverEvent` or `PointerMoveEvent` (`input_model.dart:1604-1632`, `:1899-1921`). The rate is bounded by how often Windows delivers WM_MOUSEMOVE to the Flutter window, which Windows coalesces by default (MS docs, `MOUSEEVENTF_MOVE_NOCOALESCE`). | Summed and flushed every 16 ms (`relative_mouse_model.dart:167-171`, `:574-609`). On a macOS controller, none. |
| Rust controller (`flutter_ffi`, `ui_session_interface`, `client`) | None. One `Data::Message` per call (`client.rs:4303-4342`). | None. |
| Peer receive | Unbounded `std_mpsc` channel per connection (`connection.rs:554`). Events are applied in order and never dropped or merged. | Same. |
| Peer gate | `active_mouse_` returns `true`. The old local-user-priority check is commented out as "buggy ... making fast moving mouse event discarded" (`input_service.rs:1169-1232`). | Same. |
| Peer inject | One `SendInput` per event, without NOCOALESCE, so WM_MOUSEMOVE coalescing applies in the peer's apps. Raw input is not coalesced unless flagged (RAWMOUSE `MOUSE_MOVE_NOCOALESCE`). | Same. |

Related feedback loop: the peer polls its cursor every 33 ms (`run_pos`,
`input_service.rs:336-394`) and sends `CursorPosition` to every connection
except the one that injected input in the last 300 ms (`:369-378`). A follower
that is driven only by the broadcaster will not echo its cursor back while
input keeps flowing.

## 5. Out-of-screen positions and resolution mismatch

### Controller (`getPointInRemoteRect`, `input_model.dart:2390-2438`)

- Bounds are `[rect.left, rect.right]` and `[rect.top, rect.bottom]`. For a
  Windows peer the right and bottom edges are inclusive (no `-1`), so window
  snapping works (#6678) (`:2399-2406`).
- A point within 5 px outside the rect is snapped to the edge
  (`tryGetNearestRange`, `:2407-2408`, `:2038-2046`).
- Anything further out is not sent (`return null`). The one exception is a
  left-button up, which is sent so a drag can end (`:2409-2417`). When the
  pointer leaves the image, `tryMoveEdgeOnExit` sends one last move snapped to
  the nearest edge (`:2029-2036`, `setNearestEdge` `:2048-2066`).
- Because `rect` is only the selected display, a stock controller never sends a
  position on another peer monitor unless "all displays" is on.

### Peer

- **1.5.0 and later / master**: `to_absolute` (`win_impl.rs:42-51`) computes in
  i64 and clamps to `0..=65535`. A position outside the virtual desktop pins the
  cursor to the nearest edge of the virtual desktop. Any in-desktop position is
  honoured, even one on a monitor the controller is not showing, because the
  peer does not check the session's selected display. This clamp landed in
  `08affc69c` (#16329) and is only in tag 1.5.0.
- **1.4.x**: `(x - SM_XVIRTUALSCREEN) * 65535 / SM_CXVIRTUALSCREEN` in i32 with
  no clamp (`git show 1.4.6:libs/enigo/src/win/win_impl.rs:128-137`).
  Out-of-range input produces normalized values outside 0..65535, and very large
  `x` overflows. MS docs do not say what `SendInput` does with values outside
  0..65535. In practice Windows confines the cursor to the desktop, but do not
  rely on that.

### Resolution mismatch

- **Absolute**: handled entirely on the controller by `canvas.scale` and
  `rect`. The peer only converts its own pixels to the 65535 normalized range
  against its own virtual-screen metrics. Two followers with different
  resolutions get different pixel numbers for the same leader position, but
  only if the controller maps each one through that follower's own `rect`.
  There is no peer-side normalization to lean on.
- **Relative**: nothing compensates. A delta measured in the controller's
  logical pixels is injected as-is and then accelerated by the peer's
  ballistics. The same delta moves a 4K follower's cursor a smaller fraction of
  the screen than a 1080p follower's.

## 6. Implications for input broadcast (facts only, no design decided)

- With a stock peer, the only way to place a follower's cursor at a known spot
  is `MOUSE_TYPE_MOVE` in that peer's virtual-desktop pixels: `rect` from
  `DisplayInfo`, origin included. A "natural path, never teleport" follower
  means the controller sends the intermediate absolute points itself, because
  the peer moves straight to whatever it receives.
- Relative deltas (type 5) work only on peers 1.4.5 and newer, are not
  resolution-normalized, and are distorted by each follower's pointer-precision
  setting. They are, however, the kind raw-input games consume most naturally.
- Clicks carry no position. A follower clicks wherever its cursor is, so its
  last move must arrive before the click. Ordering per connection is preserved
  end to end (single channel, single input thread).
- Nothing in the existing pipeline throttles absolute moves, so broadcasting to
  3 followers multiplies network messages and peer `SendInput` calls 1:1 with
  leader pointer events.

## Sources

Code (this repo):
- `libs/base/protos/message.proto:176-197`
- `src/common.rs:66-92`, `:212-222`
- `src/flutter_ffi.rs:1958-2058`, `:1345-1390`
- `src/ui_session_interface.rs:1238-1307`
- `src/client.rs:4303-4342`
- `src/server/connection.rs:554`, `:1249-1270`, `:2429-2447`, `:3197-3235`, `:6491-6497`
- `src/server/input_service.rs:336-394`, `:842-846`, `:1169-1232`, `:1259-1464`
- `src/server/portable_service.rs:1543-1557`
- `src/server/display_service.rs:868-879`
- `src/main.rs:27`
- `libs/enigo/src/win/win_impl.rs:20-51`, `:139-233`
- `flutter/lib/models/input_model.dart:1361-1400`, `:1604-1632`, `:1899-1950`, `:1974-2066`, `:2105-2438`
- `flutter/lib/models/relative_mouse_model.dart:76-87`, `:167-205`, `:496-765`, `:950-980`
- `flutter/lib/utils/relative_mouse_accumulator.dart`
- `flutter/lib/models/model.dart:183-211`, `:786-810`, `:2428-2433`, `:4578-4590`
- `flutter/lib/consts.dart:308`, `:316`
- History: `998b75856` (relative mode, tags 1.4.5+), `08affc69c` (absolute clamp, tag 1.5.0); `git show 1.4.4:`, `1.4.6:` and `1.5.0:` for older behavior.

Microsoft Learn:
- MOUSEINPUT: https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-mouseinput
- SendInput: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
- RAWMOUSE: https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-rawmouse
- RAWINPUTHEADER: https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-rawinputheader
- Taking Advantage of High-Definition Mouse Movement: https://learn.microsoft.com/en-us/windows/win32/dxtecharts/taking-advantage-of-high-dpi-mouse-movement
- WM_MOUSEMOVE: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousemove
