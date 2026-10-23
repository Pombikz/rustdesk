# How heavy is decoding four game streams on one Windows PC?

Research ticket for the Windows Flutter desktop "multi-view": up to 4 remote sessions (tiles) shown in one remote window, controller side only, no protocol change.

Date: 2026-10-23. Repo state: `master` at `4d37f00af`. `hwcodec` crate pinned at `ec38ebaf` (Cargo.lock:3892). `hbb_common` submodule at `edefa08b`.

## Answer in brief

- **Decode is unlikely to be the limit. The render copy path is.** If each tile streams H.264/H.265, the GPU's fixed-function decoder has plenty of headroom. NVIDIA's indicative figures for one NVDEC engine are 694 to 903 fps of 1080p H.264 and 810 to 1641 fps of HEVC. Four 1080p60 streams need 240 fps, so roughly 15 to 35% of one engine. AMD and Intel publish no comparable figures (see "Decode budgets").
- **In the default configuration, every decoded frame goes back through the CPU.** "Use D3D rendering" (`allow-d3d-render`) is **off by default**. With it off, hardware H.264/H.265 decoding reads each frame back to system memory, converts it to RGBA with libyuv, copies it again in the texture plugin, and re-uploads it with `glTexImage2D`. At 4 x 1080p60 that is about 2 GB/s of RGBA per copy stage. In one window, all four uploads also land on one Flutter engine.
- **There is no known hard limit on concurrent decode sessions.** NVIDIA says NVDEC runs multiple contexts "with negligible context-switching penalty", limited only by throughput and memory. Intel VPL and the D3D11 API state no cap. AMD documents VCN instance counts but no session cap. A failed decoder creation already falls back to a software codec through `mark_unsupported`. As a side effect, it wipes the hardware-codec list for the whole process.
- **Each tile can already be throttled at runtime, per session, with no protocol change:** custom FPS (1 to 120), image quality (bitrate only), and codec preference. Auto-FPS is also per session, and it already lowers a tile's FPS when that tile's decoder falls behind. Note that by default sessions run at **30 fps**, not 60. 60 fps requires "Custom" quality, and on the public server it requires a direct connection (not relayed).
- **There is no per-session resolution or downscale lever** short of changing the remote display mode, which is intrusive for a game.

## 1. Codec negotiation

**The host picks the codec, from what its viewers can decode.** `Encoder::update` (`libs/scrap/src/common/codec.rs:171-325`) runs on the controlled side:

- VP8, AV1 and H.264/H.265 are only usable if *every* connected viewer reports that it can decode them (`codec.rs:193-201`).
- H.264/H.265 also need a hardware encoder on the host, either VRAM or RAM hwcodec (`codec.rs:203-236`).
- Each viewer sends a preference. The host uses the most common one among its viewers (`codec.rs:238-269`).
- On `Auto`, the order is **H.265 > H.264 > AV1 (if the AV1 test passed) > VP9**. VP8 replaces VP9/AV1 on hosts with ≤ 4 GB of RAM (`codec.rs:271-290`).
- In a multibox setup each host has one viewer (our controller), so each tile's codec is chosen independently.

**The controller advertises what it can decode** in `Decoder::supported_decodings` (`codec.rs:424-499`):

- VP8 and VP9 always.
- AV1 unless the build is 32-bit (`codec.rs:1033-1037`).
- H.264/H.265 whenever `HwRamDecoder::try_get` returns something. That includes the FFmpeg **software** fallback (`CodecInfo::soft()` at `hwcodec.rs:316-330`). So a Windows `hwcodec` build always advertises H.26x decoding. If hardware decoding is unavailable, a tile can end up decoding H.264 in software.
- The VRAM path is only added when `enable_vram_option(false) && use_texture_render` (`codec.rs:460-471`).

## 2. When hardware decoding is used on Windows

Windows x64 release builds are built with `--hwcodec --vram` (`.github/workflows/flutter-build.yml:168,332`). Windows-on-ARM is built without `vram` (`flutter-build.yml:176-178`).

`Decoder::new` (`codec.rs:501-620`) tries decoders in this order for H.264/H.265:

1. **VRAM decoder (`VRamDecoder`).** Used only if `enable_vram_option(false)` is true and the renderer reported a non-zero adapter LUID (`codec.rs:536-545`).
   - `enable_vram_option(false)` = `enable-hwcodec` AND `allow-d3d-render` (`codec.rs:863-879`, `codec.rs:888-891`).
   - `allow-` options default to **false** unless set to `"Y"`, while `enable-` options default to true (`option2bool` in `hbb_common/src/config.rs:2826-2838` at `edefa08b`). So the VRAM path is **opt-in**: Settings, "Use D3D rendering" (`flutter/lib/desktop/pages/desktop_setting_page.dart:588-593`). Its tooltip warns of black screens on some machines (`src/lang/en.rs:230`).
   - The LUID comes from `flutter_gpu_texture_renderer_plugin.dll`, and only when texture rendering is on (`src/flutter.rs:1801-1830`).
   - Implementation: FFmpeg D3D11VA decode on that adapter. NV12 is converted to BGRA on the GPU (video processor or shader), and the frame is handed over as an `ID3D11Texture2D` (hwcodec `cpp/ffmpeg_vram/ffmpeg_vram_decode.cpp`, `reset()` / `convert()`). Each decoder creates its own `NativeDevice` (D3D11 device) on the LUID's adapter (`ffmpeg_vram_decode.cpp:110-123`).
2. **RAM decoder (`HwRamDecoder`).** FFmpeg with `AV_HWDEVICE_TYPE_D3D11VA` for both h264 and hevc. On Windows NVDEC (cuvid) is deliberately disabled ("windows disable nvdec to avoid gpu stuck") (hwcodec `src/ffmpeg_ram/decode.rs`).
   - Each frame is copied back to system memory with `av_hwframe_transfer_data` (`ffmpeg_ram_decode.cpp:205`).
   - On Windows it is then converted NV12 → I420 → ABGR with libyuv (`hwcodec.rs:384-440`; comment at `:395`).
   - Hardware RAM decoders use `thread_count = 1`. The software fallback uses `codec_thread_num(16)` (`ffmpeg_ram_decode.cpp:104-105`, `hwcodec.rs:357-361`).
3. **VP8/VP9 (libvpx) and AV1 (libaom).** Always software on the controller.
   - Each decoder gets `codec_thread_num(64)` threads (`vpxcodec.rs:463`, `aom.rs:451`).
   - `codec_thread_num` (`codec.rs:973-1031`) sizes threads from the one-minute CPU load and available RAM, capped at `num_cpus/2`, and is evaluated **per decoder at creation**. Four decoders can therefore each claim up to half the cores, oversubscribing the CPU 2x. Sessions opened later see a higher CPU load and get fewer threads.

Because both hardware paths go through D3D11VA (DXVA), they are vendor-neutral. The same code drives NVIDIA NVDEC, AMD VCN and Intel Quick Sync media engines through the driver. RustDesk never calls the NVDEC, AMF or VPL SDKs directly for decoding on Windows.

**Hardware availability is tested once, with one decoder per codec.** The check feeds one 720p sample per codec (`DATA_H264_720P` / `DATA_H265_720P` in hwcodec `src/ffmpeg_ram/decode.rs` and `src/vram/decode.rs`). Nothing tests whether N decoders can run at once.

## 3. Can several hardware decoders run at once? Known limits

| Vendor / API | What the primary source says |
|---|---|
| NVIDIA NVDEC | "natively supports multiple hardware decoding contexts with negligible context-switching penalty". Subject to "the hardware performance limit and available memory, an application can decode multiple videos simultaneously". "All GeForce products consist of a single NVDEC". No decode session cap is stated. (NVDEC Application Note, Video Codec SDK 13.0) |
| AMD VCN / AMF | The AMF wiki lists VCN **instances** per GPU: 1 on RX 66xx/67xx, RX 75xx/76xx, RX 906x/907x and Ryzen APUs; 2 on RX 68xx/69xx and RX 77xx-79xx. RX 63xx-65xx is "Decode only". No session cap or throughput figure is published. (GPUOpen AMF wiki, "GPU and APU HW Features and Support") |
| Intel VPL (Quick Sync) | "Each Intel® VPL session can run exactly one instance of the DECODE, ENCODE, and VPP functions". Running more requires more sessions. No maximum is stated. (Intel VPL programming guide, Sessions) |
| Microsoft D3D11 | `ID3D11VideoDevice::CreateVideoDecoder` documents no decoder-count limit, only a generic failure HRESULT. |

**How RustDesk behaves if creating a decoder fails** (for example, a driver refusing a fifth context):

- `VideoHandler` keeps the invalid decoder. The video thread then marks the codec in `lc.mark_unsupported` and re-sends `SupportedDecoding`, and the host re-negotiates to another codec, normally VP9 or AV1 in software (`src/client.rs:4090-4109`).
- **Process-wide side effect:** `HwRamDecoder::new` / `VRamDecoder::new` call `HwCodecConfig::clear(...)` on failure (`hwcodec.rs:365`, `vram.rs:366`). That empties the in-memory `ram_decode` / `vram_decode` list for the **whole process**. The list is fetched only once per process (`get_hwcodec_config` with `Once`, `src/client.rs:4195-4215`).
- Every remote window is the same process (`desktop_multi_window` creates extra `FlutterViewController`s in-process, `flutter/windows/runner/flutter_window.cpp:148-156`). So after one failure, any later decoder reset in any session falls back. RAM falls back to FFmpeg software H.264; VRAM falls back to RAM.

## 4. How the render path scales with four sessions in one window

Each session has its own `FlutterHandler`, with its own `session_handlers` map and `VideoRenderer` (`src/flutter.rs:238-312`). Each display gets its own decode thread from `start_video_thread` (`src/client.rs:3980-4129`). Nothing is serialized between sessions in Rust apart from short `RwLock`s. Decode cost therefore scales linearly per tile.

`TextureModel.updateCurrentDisplay` creates **both** a pixel-buffer texture and a GPU texture for each display (`flutter/lib/models/desktop_render_texture.dart:183-225`). Which one Flutter shows depends on which path delivered the frame (`setTextureType`, `:126-129`, `:150-166`).

**Pixel-buffer path** (VP8/VP9/AV1, `HwRamDecoder`, or texture render with D3D off). Per frame and per tile:

1. Decode into `ImageRgb` (ABGR) in Rust. RAM hardware decoding adds a GPU→CPU readback plus NV12→I420→ABGR (`hwcodec.rs:384-440`).
2. `VideoRenderer::on_rgba` calls `FlutterRgbaRendererPluginOnRgba` (`src/flutter.rs:480-526`). The plugin **copies** the buffer (`buffer_tmp_[bg].assign(...)` in `texture_rgba.cpp:42-57`, `flutter_texture_rgba_renderer@42797e0`). It then calls `MarkTextureFrameAvailable`.
3. The Flutter Windows embedder **re-uploads** the whole buffer with `glTexImage2D` every frame (`external_texture_pixelbuffer.cc`, `CopyPixelBuffer`).

A 1080p RGBA frame is 1920 x 1080 x 4 = 8.29 MB. At 60 fps that is 498 MB/s per tile and **about 2.0 GB/s for four tiles, for each of the three RGBA stages** (convert, plugin copy, upload). The RAM hardware path also reads 3.1 MB of NV12 back per frame.

Today four sessions live in four windows, so four engines each do their own uploads. A one-window multi-view puts all four `glTexImage2D` uploads on **one** engine's raster thread. That is an inference from Flutter's one-raster-thread-per-engine design; it has not been measured here.

**GPU texture path** (`VRamDecoder`, D3D rendering on):

- `on_texture` passes the decoder's BGRA `ID3D11Texture2D` to `FlutterGpuTextureRendererPluginCApiSetTexture` (`src/flutter.rs:529-553`, `:886-898`).
- The plugin does one GPU `CopyResource` into a shared texture and publishes it as a `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` surface (`d3d11_output.cpp:65-127`, `flutter_gpu_texture_renderer@08a471b`).
- No frame data touches the CPU. Four tiles cost four small GPU copies plus compositing.
- **This is the path a multi-view should prefer.** It only applies to H.264/H.265, and only when the host has a hardware encoder.

## 5. Per-session controls that lower a tile's cost (no protocol change)

All of these exist today and are sent as `Misc::Option` / `OptionMessage` on that session's connection only.

| Lever | Runtime? | Per session? | Code path | Effect on controller cost |
|---|---|---|---|---|
| Custom FPS | Yes | Yes (saved per peer as `custom-fps`) | `session_set_custom_fps` (`src/flutter_ffi.rs:576`) → `Session::set_custom_fps` (`src/ui_session_interface.rs:513-516`) → `LoginConfigHandler::set_custom_fps` (`src/client.rs:3586-3603`) → host `user_custom_fps`, clamped 1-120 (`src/server/connection.rs:4930-4935`, `src/server/video_qos.rs:417-424`) | Linear: halving FPS halves decode, convert and upload cost. **Strongest lever.** |
| Auto FPS | Automatic | Yes (one `io_loop` per session) | `Remote::fps_control` (`src/client/io_loop.rs:1396-1510`): limits FPS to about 90% (direct) or 80% (relay) of measured decode FPS, halves it when the queue backs up, and caps it at custom FPS | A tile whose decoder slows under contention self-throttles. A shared bottleneck therefore degrades every tile's FPS rather than adding latency. |
| Image quality (Best/Balanced/Low/Custom %) | Yes | Yes | `session_set_image_quality` / `session_set_custom_image_quality` (`src/flutter_ffi.rs:475,570`) → host `user_image_quality` (`video_qos.rs:435-456`) | Changes the bitrate ratio only (`BR_BEST 1.5`, `BR_BALANCED 0.67`, `BR_SPEED 0.5`, `codec.rs:893-927`). Resolution is unchanged. Small saving for software decoding, negligible for hardware. |
| Codec preference | Yes | Yes (`codec-preference` per peer) | `session_change_prefer_codec` (`src/flutter_ffi.rs:2123-2127`) → `update_supported_decodings` (`src/ui_session_interface.rs:562-565`) → host `Encoder::update` | Lets a tile be pinned to H.264/H.265 (hardware decoding) or moved off it. Only works if the host has a hardware encoder (`alternative_codecs`, `ui_session_interface.rs:541-560`). |
| 4:4:4 chroma (`i444`) | Yes (codec re-negotiation) | Yes | `Decoder::preference` (`codec.rs:819-849`) | Off by default. Leave it off: 4:4:4 roughly doubles the chroma data. |
| Change remote resolution | Yes | Yes | `session_change_resolution` (`src/flutter_ffi.rs:961`) | Changes the **host's display mode**. Intrusive for a running game, so not a viewer-side downscale. |
| D3D rendering / hwcodec | Yes (resets decoders, `ui_session_interface.rs:567-571`) | **No**: global `LocalConfig` / `Config` | `allow-d3d-render`, `enable-hwcodec` | Moves H.26x tiles to the zero-copy GPU path. |

Caveats for gaming at 60 fps:

- **Defaults are 30 fps.** The host's default per-user cap is `FPS = 30` (`video_qos.rs:51`, `:273-281`). Choosing any non-Custom quality resets custom FPS to 30 (`ui_session_interface.rs:494-506`). At login, custom FPS is only sent when quality is "custom" (`src/client.rs:3373-3397`).
- **The public server caps FPS at 30 unless the connection is direct.** With the public rendezvous server and a relayed connection, custom FPS is capped at 30 at login (`src/client.rs:3378,3392-3394`). The FPS slider is hidden in that case (`flutter/lib/common/widgets/dialog.dart:1839-1841`). `set_custom_fps` itself does not cap, so a value set at runtime goes through until the next login.
- **There is no per-session encode downscale.** A "small tile gets a low-resolution stream" option would need a protocol change. Out of scope.

## 6. Rough decode budgets for 4 x 1080p60

The load is 240 frames/s at 1920x1080 4:2:0 (or 120 frames/s at the default 30 fps).

**NVIDIA.** These are the "NVDEC Decoding Performance (Indicative)" figures, per NVDEC engine, 1920x1080 4:2:0, at the highest video clock, Windows 11, SDK 13.0. They "scale roughly with the video clock".

| Architecture (GeForce example) | H.264 fps | 4x1080p60 share | HEVC fps | 4x1080p60 share |
|---|---|---|---|---|
| Pascal (GTX 10xx) | 694 | 35% | 810 | 30% |
| Turing (GTX 16xx / RTX 20xx) | 771 | 31% | 1316 | 18% |
| Ampere (RTX 30xx) | 748 | 32% | 1415 | 17% |
| Ada (RTX 40xx) | 903 | 27% | 1641 | 15% |
| Blackwell (RTX 50xx) | 2172 | 11% | 1872 | 13% |

These figures use the NVDECODE API directly. RustDesk goes through D3D11VA, which drives the same engine, but the D3D11VA overhead has not been measured. A GPU at idle may also run below the peak video clock.

**AMD (VCN) and Intel (Quick Sync).** Neither vendor publishes official per-engine decode throughput for consumer parts:

- AMD's AMF wiki gives codec and resolution support and instance counts, but no fps.
- Intel's oneAPI GPU optimisation guide describes the media engine as independent of the compute engines, with "its own instruction queue and clock", but gives no fps.
- Intel's community forum suggests roughly 16 decode sessions "especially at lower resolution". That is a low-trust, non-spec figure; treat it as a hint only.
- Treat both as **unknown until measured**. Four 1080p60 H.264/HEVC streams are within the published 4K60 and 8K capability of VCN 2.0+ and Xe media engines by pixel rate (one 4K60 stream ≈ 4 x 1080p60). That is an inference, not a vendor claim.

**Software (VP9 via libvpx, AV1 via libaom).** No primary-source benchmark was found for 1080p60 decoding on consumer CPUs. These cases need measuring. They are also hurt by the per-decoder `codec_thread_num` oversubscription described in section 2.

## 7. Implications for the multi-view design

1. Recommend, or detect and prompt for, **"Use D3D rendering" + H.264/H.265** for multi-view. Only that path keeps four game streams off the CPU and off the single raster thread.
2. Use **per-tile custom FPS** as the main cost lever. One option is to keep the focused tile at 60 and drop unfocused tiles to 15-30. This is already runtime and per session, with no protocol change. Auto-FPS stays as the safety net.
3. Expect the **pixel-buffer path** (any VP9/AV1 tile, or D3D rendering off) to scale worst. Budget about 2 GB/s per RGBA copy stage at 4 x 1080p60, on one raster thread.
4. Watch the **process-global `HwCodecConfig::clear`** on a decoder-creation failure. With four sessions in one process, one transient failure downgrades the others on their next decoder reset. That is a pre-existing behaviour, not something the multi-view introduces.

## Open questions (need measurement)

- Real 4-tile numbers on representative NVIDIA, AMD and Intel GPUs: decode ms/frame, CPU %, and raster-thread time with D3D rendering on and off.
- Whether one Flutter engine compositing four pixel-buffer textures at 60 fps holds 60 fps on mid-range CPUs.
- Whether any consumer driver refuses a fourth or fifth D3D11VA decoder in one process. No vendor documents such a limit.

## Sources

Repository (file:line as cited above): `libs/scrap/src/common/{codec.rs,hwcodec.rs,vram.rs,vpxcodec.rs,aom.rs}`, `src/client.rs`, `src/client/io_loop.rs`, `src/flutter.rs`, `src/flutter_ffi.rs`, `src/ui_session_interface.rs`, `src/ui_interface.rs:190-220`, `src/server/{connection.rs,video_qos.rs}`, `flutter/lib/models/desktop_render_texture.dart`, `flutter/lib/common/widgets/{toolbar.dart,dialog.dart}`, `flutter/windows/runner/flutter_window.cpp`, `.github/workflows/flutter-build.yml`.

Pinned dependencies:
- rustdesk-org/hwcodec @ `ec38ebaf`: `src/ffmpeg_ram/decode.rs`, `src/vram/decode.rs`, `cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp`, `cpp/ffmpeg_vram/ffmpeg_vram_decode.cpp` — https://github.com/rustdesk-org/hwcodec
- rustdesk-org/flutter_texture_rgba_renderer @ `42797e0`: `windows/texture_rgba.cpp`, `windows/texture_rgba_renderer_plugin_c_api.cpp`
- rustdesk-org/flutter_gpu_texture_renderer @ `08a471b`: `windows/d3d11_output.cpp`
- rustdesk/hbb_common @ `edefa08b`: `src/config.rs:2826-2838` (`option2bool`)

Vendor and platform docs:
- NVIDIA, NVDEC Application Note (Video Codec SDK 13.0): https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvdec-application-note/index.html
- AMD GPUOpen, AMF wiki "GPU and APU HW Features and Support": https://github.com/GPUOpen-LibrariesAndSDKs/AMF/wiki/GPU-and-APU-HW-Features-and-Support
- Intel VPL programming guide, Sessions: https://intel.github.io/libvpl/latest/programming_guide/VPL_prg_session.html
- Intel oneAPI GPU Optimization Guide, Media Engine Hardware: https://www.intel.com/content/www/us/en/docs/oneapi/optimization-guide-gpu/2025-2/media-engine-hardware.html
- Intel community forum (low trust, anecdotal): https://community.intel.com/t5/Media-Intel-Video-Processing/QSV-performance/td-p/1035157
- Microsoft, `ID3D11VideoDevice::CreateVideoDecoder`: https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videodevice-createvideodecoder
- Flutter engine, Windows pixel-buffer texture upload: https://github.com/flutter/engine/blob/main/shell/platform/windows/external_texture_pixelbuffer.cc
