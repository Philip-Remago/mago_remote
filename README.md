# mago_remote

A private Flutter plugin that wraps a LiveKit-based remote-desktop session into a
three-class API.  
Consuming apps supply all UI/Scaffold; the plugin handles the LiveKit connection,
input injection, screen capture, and gesture translation.

---

## Table of contents

1. [Installation](#installation)
2. [Quick-start](#quick-start)
3. [API reference](#api-reference)
   - [TokenClient](#tokenclient)
   - [ControllerSession](#controllersession)
   - [RemoteVideoView / RemoteVideoViewController](#remotevideoview--remotevideoviewcontroller)
   - [HostSession](#hostsession)
   - [DisplayInfo](#displayinfo)
4. [Platform notes](#platform-notes)
   - [Android](#android)
   - [Windows](#windows)
   - [macOS](#macos)
5. [Architecture](#architecture)

---

## Installation

Add to `pubspec.yaml`:

```yaml
dependencies:
  mago_remote:
    git:
      url: https://github.com/your-org/mago_remote.git
      # or a local path during development:
      # path: ../mago_remote
```

---

## Quick-start

### Host (screen-sharing side)

```dart
import 'package:mago_remote/mago_remote.dart';

class _HostPageState extends State<HostPage> {
  final _session = HostSession();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final token = await TokenClient('https://your-server/token').fetchToken(
      room: 'room-1',
      identity: 'host-device',
      role: 'host',
    );
    await _session.start(
      liveKitUrl: 'wss://your-livekit-server.livekit.cloud',
      token: token,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<HostState>(
      stream: _session.stateStream,
      builder: (_, snap) {
        final state = snap.data ?? HostState.idle;
        return Scaffold(
          body: Center(child: Text(state.name)),
          floatingActionButton: state == HostState.idle
              ? FloatingActionButton(
                  onPressed: _start,
                  child: const Icon(Icons.play_arrow),
                )
              : FloatingActionButton(
                  onPressed: _session.stop,
                  child: const Icon(Icons.stop),
                ),
        );
      },
    );
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }
}
```

### Controller (remote-control side)

```dart
import 'package:mago_remote/mago_remote.dart';

class _ControllerPageState extends State<ControllerPage> {
  final _session = ControllerSession();
  final _videoController = RemoteVideoViewController();

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final token = await TokenClient('https://your-server/token').fetchToken(
      room: 'room-1',
      identity: 'controller-device',
      role: 'controller',
    );
    await _session.connect(
      liveKitUrl: 'wss://your-livekit-server.livekit.cloud',
      token: token,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RemoteVideoView(
        session: _session,
        controller: _videoController,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _videoController.toggleKeyboard,
        child: const Icon(Icons.keyboard),
      ),
    );
  }

  @override
  void dispose() {
    _session.dispose();
    _videoController.dispose();
    super.dispose();
  }
}
```

---

## API reference

### TokenClient

```dart
final client = TokenClient('https://your-server/token');

final jwt = await client.fetchToken(
  room: 'room-1',       // LiveKit room name
  identity: 'alice',    // Participant identity
  role: 'host',         // 'host' | 'controller' — forwarded to your server
  pairingCode: '482910' // Optional; forwarded to your server for validation
);
```

Throws `TokenException` on HTTP error or non-200 response.

---

### ControllerSession

Manages the LiveKit connection from the controller side.  
All streams are **broadcast** — multiple listeners are allowed.

```dart
final session = ControllerSession();

// Connect
await session.connect(liveKitUrl: wsUrl, token: jwt);

// Streams
session.stateStream      // Stream<ControllerState>
session.videoTrackStream // Stream<VideoTrack?>
session.hostInfoStream   // Stream<HostScreenInfo>
session.imeStateStream   // Stream<bool>  — true = show keyboard

// Current values
session.state            // ControllerState
session.currentVideoTrack
session.hostWidth / hostHeight
session.isNativeTouchHost
session.isConnected
session.lastError        // String?

// Send an input event manually (rarely needed — RemoteVideoView handles this)
session.sendEvent(mouseEvent);

// Teardown
await session.disconnect();
await session.dispose();
```

**ControllerState** values: `disconnected`, `connecting`, `connected`, `error`.

---

### RemoteVideoView / RemoteVideoViewController

`RemoteVideoView` is a `StatefulWidget` that renders the host video and
forwards all pointer/keyboard/scroll input to the session automatically.

```dart
RemoteVideoView(
  session: session,                 // required ControllerSession
  controller: videoController,      // optional RemoteVideoViewController
  backgroundColor: Colors.black,    // default
  showBorder: true,                 // default
  showResetZoomButton: true,        // default
  maxZoom: 5.0,                     // default
)
```

`RemoteVideoViewController extends ChangeNotifier`:

```dart
final vc = RemoteVideoViewController();

vc.isKeyboardVisible  // bool
vc.showKeyboard()
vc.hideKeyboard()
vc.toggleKeyboard()
```

Dispose the controller yourself:

```dart
@override
void dispose() {
  vc.dispose();
  super.dispose();
}
```

---

### HostSession

Manages screen sharing and input injection on the host side.

```dart
final session = HostSession();

// Display the pairing code to the user.
print(session.pairingCode);  // e.g. "482910"

// Check / request platform permissions before calling start().
final ready = await session.isInjectorReady();
if (!ready) await session.requestInjectorPermissions();

// Start sharing.
await session.start(
  liveKitUrl: wsUrl,
  token: jwt,
  sourceId: null,  // desktop: pass a DesktopCapturerSource.id; null = auto-pick primary
);

// Streams
session.stateStream    // Stream<HostState>
session.displaysStream // Stream<List<DisplayInfo>>  (desktop platforms)

// Current values
session.state          // HostState
session.displays       // List<DisplayInfo>
session.activeDisplay  // DisplayInfo?
session.lastError      // String?

// Switch monitor (desktop only)
await session.switchSource(sourceId);

// Stop sharing
await session.stop();

// Full teardown
await session.dispose();
```

**HostState** values: `idle`, `starting`, `connected`, `error`.

---

### DisplayInfo

Describes a physical monitor on desktop platforms.

```dart
class DisplayInfo {
  final String id;
  final int x, y;          // origin in virtual screen coordinates
  final int width, height; // resolution in physical pixels
  final double scale;      // device pixel ratio
  final String label;
  final bool isPrimary;
}
```

---

## Platform notes

### Android

The plugin ships an `AndroidManifest.xml` fragment that Gradle's manifest
merger automatically merges into the consuming app's manifest. No manual
changes are required **unless** you also target Android 13+ and need
`POST_NOTIFICATIONS` for your own notification channels (that permission is
already in the plugin manifest via the `FOREGROUND_SERVICE` declaration).

**AccessibilityService setup**

On the host side, the user must manually enable
*Remote Desk Input* in **Settings › Accessibility**. Guide them to this screen
by calling:

```dart
await const MethodChannel('remote_desk/android_input')
    .invokeMethod('openAccessibilitySettings');
```

or check with:

```dart
final bool enabled = await session.isInjectorReady();
```

**MediaProjection**

`HostSession.start()` calls `flutter_webrtc`'s
`Helper.requestCapturePermission()` automatically before launching
`ScreenCaptureService`.

---

### Windows

Input injection is done via Win32 `SendInput` — no special permissions are
needed. The host user must run the app as a normal (non-elevated) account;
`SendInput` cannot inject events into elevated windows from a non-elevated
process (this is an OS security boundary).

---

### macOS

Input injection uses the CoreGraphics framework loaded via FFI.
The consuming app must have the **Accessibility** entitlement
(`com.apple.security.automation.apple-events`) and the user must grant Screen
Recording permission when the host starts sharing.

Add to `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.automation.apple-events</key>
<true/>
```

---

## Architecture

```
mago_remote/
├── lib/
│   ├── mago_remote.dart            ← public barrel (only export from here)
│   └── src/
│       ├── protocol/
│       │   └── input_event.dart    ← wire protocol: InputEvent subclasses,
│       │                              encode/decode, kProtocolVersion=2
│       ├── livekit/
│       │   ├── room_session.dart   ← thin Room lifecycle wrapper
│       │   └── token_client.dart   ← HTTP POST to your token endpoint
│       ├── controller/
│       │   ├── controller_session.dart   ← LiveKit + data-channel glue
│       │   ├── remote_video_view.dart    ← StatefulWidget + ViewController
│       │   ├── gesture_translator.dart   ← PointerEvent → InputEvent
│       │   └── ime_bridge.dart           ← OS IME → remote keystrokes
│       └── host/
│           ├── host_session.dart         ← screen-share + injection lifecycle
│           ├── display_info.dart         ← monitor descriptor
│           ├── focus_watcher.dart        ← "editable focused?" stream
│           ├── screen_enumerator.dart    ← list/match physical monitors
│           └── injector/
│               ├── input_injector.dart   ← abstract interface + factory
│               ├── android_injector.dart ← routes to MethodChannel
│               ├── windows_injector.dart ← Win32 SendInput via win32 pkg
│               ├── mac_injector.dart     ← CoreGraphics FFI
│               ├── noop_injector.dart    ← stub for unsupported platforms
│               └── key_mapping.dart      ← HID USB → Win VK / macOS kVK
└── android/
    ├── build.gradle
    └── src/main/
        ├── AndroidManifest.xml
        ├── res/
        │   ├── values/strings.xml
        │   └── xml/accessibility_service_config.xml
        └── kotlin/com/magoremote/mago_remote/
            ├── MagoRemotePlugin.kt    ← FlutterPlugin, registers channels
            ├── RemoteInputService.kt  ← AccessibilityService, gesture/text
            ├── GestureSession.kt      ← multi-pointer dispatchGesture engine
            └── ScreenCaptureService.kt ← FGS mediaProjection
```

### Wire protocol

All messages are compact JSON bytes encoded as UTF-8.

| Field | Meaning |
|-------|---------|
| `v`   | Protocol version (always `2`) |
| `t`   | Event type (see below) |

| Type | Payload |
|------|---------|
| `mouseMove`   | `x`, `y` (0..1 normalized) |
| `mouseButton` | `b` button index, `d` down flag, `x`, `y` |
| `mouseWheel`  | `dx`, `dy` (pixels, can be fractional) |
| `keyEvent`    | `k` HID usage id, `d` down flag, `m` modifier bitmask |
| `text`        | `s` string |
| `screenInfo`  | `w`, `h` (pixels), `nt` native-touch flag |
| `ping`        | (empty payload) |
| `imeState`    | `open` bool |
| `touchDown`   | `id` pointer, `x`, `y` |
| `touchMove`   | `id` pointer, `x`, `y` |
| `touchUp`     | `id` pointer, `x`, `y` |
