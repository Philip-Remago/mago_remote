import 'dart:convert';
import 'dart:typed_data';

/// Versioned wire protocol for input events sent from Controller -> Host
/// and capability/screen info sent Host -> Controller.
///
/// Uses compact JSON for portability. All coordinates are normalized to
/// [0.0, 1.0] of the host's primary capture surface; the host scales
/// them to physical pixels using its own [ScreenInfo].
///
/// v2: KeyInputEvent gained `capsLock` field; older peers send v1 with
/// no capsLock and we decode missing field as 0 (matches v1 semantics).
/// v2 decoders accept v1 payloads transparently.
///
/// `DisplaysInfoEvent` and `SwitchDisplayEvent` were added on top of v2
/// without bumping the wire version: older peers fall through the
/// `EventType.values.firstWhere` and return null for the unknown name,
/// which is caught by the outer try/catch. New peers stay binary
/// compatible with old peers on every event they already understand.
const int kProtocolVersion = 2;

enum EventType {
  mouseMove,
  mouseButton,
  mouseWheel,
  keyEvent,
  text,
  screenInfo,
  ping,
  imeState,
  // Native multi-pointer touch events. Carry a stable pointer id so the
  // host can drive a real held-finger gesture (long-press, drag,
  // pinch). Controllers only emit these when the host advertises
  // `ScreenInfoEvent.nativeTouch == true`; otherwise they fall back to
  // synthesizing left-click / right-click / drag from MouseButton +
  // MouseMove pairs.
  touchDown,
  touchMove,
  touchUp,
  // Host -> Controller: list of available monitors plus the currently
  // active one. Re-broadcast whenever the set changes or a controller
  // joins. Controller -> Host: request a switch to a specific source id.
  displaysInfo,
  switchDisplay,
}

enum MouseButton { left, right, middle }

abstract class InputEvent {
  EventType get type;
  Map<String, dynamic> toJson();

  Uint8List encode() {
    final m = {'v': kProtocolVersion, 't': type.name, 'd': toJson()};
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  static InputEvent? decode(List<int> bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      // Accept any version <= current; new fields default to backward-
      // compatible values. Reject newer-version traffic so we don't
      // silently misinterpret unknown semantics.
      final v = (m['v'] as num?)?.toInt() ?? 0;
      if (v == 0 || v > kProtocolVersion) return null;
      final t = EventType.values.firstWhere((e) => e.name == m['t']);
      final d = (m['d'] as Map).cast<String, dynamic>();
      switch (t) {
        case EventType.mouseMove:
          return MouseMoveEvent(
            x: (d['x'] as num).toDouble(),
            y: (d['y'] as num).toDouble(),
          );
        case EventType.mouseButton:
          return MouseButtonEvent(
            button: MouseButton.values.firstWhere((b) => b.name == d['b']),
            down: d['down'] as bool,
            x: (d['x'] as num).toDouble(),
            y: (d['y'] as num).toDouble(),
          );
        case EventType.mouseWheel:
          return MouseWheelEvent(
            dx: (d['dx'] as num).toDouble(),
            dy: (d['dy'] as num).toDouble(),
          );
        case EventType.keyEvent:
          return KeyInputEvent(
            logicalKey: (d['lk'] as num).toInt(),
            physicalKey: (d['pk'] as num).toInt(),
            down: d['down'] as bool,
            modifiers: (d['mods'] as num).toInt(),
            // v1 peers omit `caps`; treat as off (matches v1 behaviour).
            capsLock: (d['caps'] as bool?) ?? false,
          );
        case EventType.text:
          return TextEvent(text: d['s'] as String);
        case EventType.screenInfo:
          return ScreenInfoEvent(
            width: (d['w'] as num).toInt(),
            height: (d['h'] as num).toInt(),
            scale: (d['s'] as num).toDouble(),
            nativeTouch: (d['nt'] as bool?) ?? false,
          );
        case EventType.ping:
          return PingEvent(stamp: (d['ts'] as num).toInt());
        case EventType.imeState:
          return ImeStateEvent(open: d['o'] as bool);
        case EventType.touchDown:
          return TouchDownEvent(
            id: (d['id'] as num).toInt(),
            x: (d['x'] as num).toDouble(),
            y: (d['y'] as num).toDouble(),
          );
        case EventType.touchMove:
          return TouchMoveEvent(
            id: (d['id'] as num).toInt(),
            x: (d['x'] as num).toDouble(),
            y: (d['y'] as num).toDouble(),
          );
        case EventType.touchUp:
          return TouchUpEvent(
            id: (d['id'] as num).toInt(),
            x: (d['x'] as num).toDouble(),
            y: (d['y'] as num).toDouble(),
            cancel: (d['c'] as bool?) ?? false,
          );
        case EventType.displaysInfo:
          final list = (d['ds'] as List?) ?? const [];
          return DisplaysInfoEvent(
            displays: list
                .map(
                  (e) => DisplayDescriptor.fromJson(
                    (e as Map).cast<String, dynamic>(),
                  ),
                )
                .toList(growable: false),
            activeSourceId: d['active'] as String?,
          );
        case EventType.switchDisplay:
          return SwitchDisplayEvent(sourceId: d['sid'] as String);
      }
    } catch (_) {
      return null;
    }
  }
}

class MouseMoveEvent extends InputEvent {
  MouseMoveEvent({required this.x, required this.y});
  final double x; // 0..1
  final double y; // 0..1
  @override
  EventType get type => EventType.mouseMove;
  @override
  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

class MouseButtonEvent extends InputEvent {
  MouseButtonEvent({
    required this.button,
    required this.down,
    required this.x,
    required this.y,
  });
  final MouseButton button;
  final bool down;
  final double x;
  final double y;
  @override
  EventType get type => EventType.mouseButton;
  @override
  Map<String, dynamic> toJson() => {
    'b': button.name,
    'down': down,
    'x': x,
    'y': y,
  };
}

class MouseWheelEvent extends InputEvent {
  MouseWheelEvent({required this.dx, required this.dy});
  final double dx;
  final double dy;
  @override
  EventType get type => EventType.mouseWheel;
  @override
  Map<String, dynamic> toJson() => {'dx': dx, 'dy': dy};
}

/// Modifier bits.
class KeyMods {
  static const int shift = 1 << 0;
  static const int ctrl = 1 << 1;
  static const int alt = 1 << 2;
  static const int meta = 1 << 3; // Win/Cmd
}

class KeyInputEvent extends InputEvent {
  KeyInputEvent({
    required this.logicalKey,
    required this.physicalKey,
    required this.down,
    required this.modifiers,
    this.capsLock = false,
  });
  final int logicalKey; // Flutter LogicalKeyboardKey.keyId
  final int physicalKey; // Flutter PhysicalKeyboardKey.usbHidUsage
  final bool down;
  final int modifiers;

  /// Toggle state of CapsLock on the controller at the moment this key
  /// event was emitted. The host reconciles its own CapsLock toggle to
  /// match before injecting the key, so Shift+a vs CapsLock+a both
  /// produce 'A' on the host.
  final bool capsLock;

  @override
  EventType get type => EventType.keyEvent;
  @override
  Map<String, dynamic> toJson() => {
    'lk': logicalKey,
    'pk': physicalKey,
    'down': down,
    'mods': modifiers,
    'caps': capsLock,
  };
}

class TextEvent extends InputEvent {
  TextEvent({required this.text});
  final String text;
  @override
  EventType get type => EventType.text;
  @override
  Map<String, dynamic> toJson() => {'s': text};
}

class ScreenInfoEvent extends InputEvent {
  ScreenInfoEvent({
    required this.width,
    required this.height,
    required this.scale,
    this.nativeTouch = false,
  });
  final int width;
  final int height;
  final double scale;

  /// True when the host can consume `TouchDown/Move/Up` events natively
  /// (Android's AccessibilityService gestures). Tells the controller it
  /// should send raw pointer events instead of synthesizing mouse
  /// taps/drags/long-presses on the wire.
  final bool nativeTouch;

  @override
  EventType get type => EventType.screenInfo;
  @override
  Map<String, dynamic> toJson() => {
    'w': width,
    'h': height,
    's': scale,
    'nt': nativeTouch,
  };
}

class PingEvent extends InputEvent {
  PingEvent({required this.stamp});
  final int stamp;
  @override
  EventType get type => EventType.ping;
  @override
  Map<String, dynamic> toJson() => {'ts': stamp};
}

/// Host -> Controller hint that the focus on the host is currently on (or
/// has just left) an editable text field. Touch-only controllers use this
/// to pop up / dismiss the OS soft keyboard automatically.
class ImeStateEvent extends InputEvent {
  ImeStateEvent({required this.open});
  final bool open;
  @override
  EventType get type => EventType.imeState;
  @override
  Map<String, dynamic> toJson() => {'o': open};
}

/// Pointer-down on a controller-side touch surface, forwarded as a
/// real held finger to a host that supports native touch gestures.
class TouchDownEvent extends InputEvent {
  TouchDownEvent({required this.id, required this.x, required this.y});

  /// Stable per-finger id (matches Flutter's `PointerEvent.pointer`).
  final int id;
  final double x; // 0..1
  final double y; // 0..1

  @override
  EventType get type => EventType.touchDown;
  @override
  Map<String, dynamic> toJson() => {'id': id, 'x': x, 'y': y};
}

/// Continuation of a finger that's already down. The host extends the
/// existing stroke so what was a tap-and-hold becomes a real drag.
class TouchMoveEvent extends InputEvent {
  TouchMoveEvent({required this.id, required this.x, required this.y});
  final int id;
  final double x;
  final double y;
  @override
  EventType get type => EventType.touchMove;
  @override
  Map<String, dynamic> toJson() => {'id': id, 'x': x, 'y': y};
}

/// Finger lifted. When [cancel] is true the host should treat it as a
/// cancellation (e.g. a system gesture stole the touch) rather than a
/// commit; differs from the platform's `PointerCancel`.
class TouchUpEvent extends InputEvent {
  TouchUpEvent({
    required this.id,
    required this.x,
    required this.y,
    this.cancel = false,
  });
  final int id;
  final double x;
  final double y;
  final bool cancel;
  @override
  EventType get type => EventType.touchUp;
  @override
  Map<String, dynamic> toJson() => {'id': id, 'x': x, 'y': y, 'c': cancel};
}

/// Lightweight wire-friendly description of one capture source advertised
/// by the host. [sourceId] is the opaque `DesktopCapturerSource.id`
/// (from flutter_webrtc) — the same identifier the host accepts in
/// [SwitchDisplayEvent].
class DisplayDescriptor {
  const DisplayDescriptor({
    required this.sourceId,
    required this.label,
    required this.isPrimary,
    required this.width,
    required this.height,
  });

  final String sourceId;
  final String label;
  final bool isPrimary;
  final int width;
  final int height;

  Map<String, dynamic> toJson() => {
    'sid': sourceId,
    'l': label,
    'p': isPrimary,
    'w': width,
    'h': height,
  };

  factory DisplayDescriptor.fromJson(Map<String, dynamic> j) =>
      DisplayDescriptor(
        sourceId: j['sid'] as String,
        label: j['l'] as String,
        isPrimary: (j['p'] as bool?) ?? false,
        width: (j['w'] as num).toInt(),
        height: (j['h'] as num).toInt(),
      );
}

/// Host -> Controller: list of all available monitors, plus the source id
/// currently being captured (if any). Sent on connect, when the active
/// monitor changes, and when the available set changes.
class DisplaysInfoEvent extends InputEvent {
  DisplaysInfoEvent({required this.displays, this.activeSourceId});

  final List<DisplayDescriptor> displays;
  final String? activeSourceId;

  @override
  EventType get type => EventType.displaysInfo;
  @override
  Map<String, dynamic> toJson() => {
    'ds': displays.map((d) => d.toJson()).toList(growable: false),
    if (activeSourceId != null) 'active': activeSourceId,
  };
}

/// Controller -> Host: request the host to start capturing the given
/// source id (must be one of the [DisplayDescriptor.sourceId] values
/// previously advertised in [DisplaysInfoEvent]).
class SwitchDisplayEvent extends InputEvent {
  SwitchDisplayEvent({required this.sourceId});
  final String sourceId;
  @override
  EventType get type => EventType.switchDisplay;
  @override
  Map<String, dynamic> toJson() => {'sid': sourceId};
}
