import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';
import 'key_mapping.dart';

// ============================================================
// CoreGraphics type aliases
// ============================================================
typedef CGFloat = Double;
typedef CGEventSourceRef = IntPtr;
typedef CGEventRef = IntPtr;
typedef CGEventTapLocation = Int32;
typedef CGMouseButton = Int32;
typedef CGEventType = Int32;
typedef CGScrollEventUnit = Int32;

const int kCGHIDEventTap = 0;
const int kCGMouseButtonLeft = 0;
const int kCGMouseButtonRight = 1;
const int kCGMouseButtonCenter = 2;

const int kCGEventLeftMouseDown = 1;
const int kCGEventLeftMouseUp = 2;
const int kCGEventRightMouseDown = 3;
const int kCGEventRightMouseUp = 4;
const int kCGEventMouseMoved = 5;
const int kCGEventLeftMouseDragged = 6;
const int kCGEventRightMouseDragged = 7;
const int kCGEventOtherMouseDown = 25;
const int kCGEventOtherMouseUp = 26;
const int kCGEventScrollWheel = 22;
const int kCGEventKeyDown = 10;
const int kCGEventKeyUp = 11;

const int kCGScrollEventUnitLine = 1;

const int kCGEventFlagMaskAlphaShift = 0x00010000; // Caps Lock

// ============================================================
// Native struct: CGPoint { double x; double y; }
// ============================================================
final class CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

// ============================================================
// FFI typedefs
// ============================================================
typedef CGEventCreateMouseEventNative =
    IntPtr Function(IntPtr, Int32, CGPoint, Int32);
typedef CGEventCreateMouseEventDart = int Function(int, int, CGPoint, int);

typedef CGEventCreateKeyboardEventNative = IntPtr Function(IntPtr, Int32, Bool);
typedef CGEventCreateKeyboardEventDart = int Function(int, int, bool);

typedef CGEventCreateScrollWheelEventNative =
    IntPtr Function(IntPtr, Int32, Int32, Int32);
typedef CGEventCreateScrollWheelEventDart = int Function(int, int, int, int);

typedef CGEventPostNative = Void Function(Int32, IntPtr);
typedef CGEventPostDart = void Function(int, int);

typedef CGEventReleaseNative = Void Function(IntPtr);
typedef CGEventReleaseDart = void Function(int);

typedef CGEventSetIntegerValueFieldNative = Void Function(IntPtr, Int32, Int64);
typedef CGEventSetIntegerValueFieldDart = void Function(int, int, int);

typedef CGEventSetFlagsNative = Void Function(IntPtr, Int64);
typedef CGEventSetFlagsDart = void Function(int, int);

typedef CGEventGetFlagsNative = Int64 Function(IntPtr);
typedef CGEventGetFlagsDart = int Function(int);

typedef CGMainDisplayIDNative = Int32 Function();
typedef CGMainDisplayIDDart = int Function();

typedef CGDisplayPixelsWideNative = Int32 Function(Int32);
typedef CGDisplayPixelsWideDart = int Function(int);

typedef CGDisplayPixelsHighNative = Int32 Function(Int32);
typedef CGDisplayPixelsHighDart = int Function(int);

typedef CGDisplayScreenSizeNative = Struct Function(Int32);

// CGEvent key field numbers (kCGKeyboardEventKeycode = 9)
const int kCGKeyboardEventKeycode = 9;

class MacInjector implements InputInjector {
  MacInjector() {
    if (!Platform.isMacOS) return;
    final cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    _createMouse = cg
        .lookupFunction<
          CGEventCreateMouseEventNative,
          CGEventCreateMouseEventDart
        >('CGEventCreateMouseEvent');
    _createKey = cg
        .lookupFunction<
          CGEventCreateKeyboardEventNative,
          CGEventCreateKeyboardEventDart
        >('CGEventCreateKeyboardEvent');
    _createScroll = cg
        .lookupFunction<
          CGEventCreateScrollWheelEventNative,
          CGEventCreateScrollWheelEventDart
        >('CGEventCreateScrollWheelEvent');
    _post = cg.lookupFunction<CGEventPostNative, CGEventPostDart>(
      'CGEventPost',
    );
    _release = cg.lookupFunction<CGEventReleaseNative, CGEventReleaseDart>(
      'CFRelease',
    );
    _setInt = cg
        .lookupFunction<
          CGEventSetIntegerValueFieldNative,
          CGEventSetIntegerValueFieldDart
        >('CGEventSetIntegerValueField');
    _setFlags = cg.lookupFunction<CGEventSetFlagsNative, CGEventSetFlagsDart>(
      'CGEventSetFlags',
    );
    _getFlags = cg.lookupFunction<CGEventGetFlagsNative, CGEventGetFlagsDart>(
      'CGEventGetFlags',
    );
    _mainDisplay = cg
        .lookupFunction<CGMainDisplayIDNative, CGMainDisplayIDDart>(
          'CGMainDisplayID',
        );
    _displayWide = cg
        .lookupFunction<CGDisplayPixelsWideNative, CGDisplayPixelsWideDart>(
          'CGDisplayPixelsWide',
        );
    _displayHigh = cg
        .lookupFunction<CGDisplayPixelsHighNative, CGDisplayPixelsHighDart>(
          'CGDisplayPixelsHigh',
        );
  }

  late final CGEventCreateMouseEventDart _createMouse;
  late final CGEventCreateKeyboardEventDart _createKey;
  late final CGEventCreateScrollWheelEventDart _createScroll;
  late final CGEventPostDart _post;
  late final CGEventReleaseDart _release;
  late final CGEventSetIntegerValueFieldDart _setInt;
  late final CGEventSetFlagsDart _setFlags;
  late final CGEventGetFlagsDart _getFlags;
  late final CGMainDisplayIDDart _mainDisplay;
  late final CGDisplayPixelsWideDart _displayWide;
  late final CGDisplayPixelsHighDart _displayHigh;

  DisplayInfo? _target;
  // Track our own flags bitmask so we can OR modifier keys in/out.
  int _flags = 0;

  @override
  Future<bool> isReady() async => Platform.isMacOS;

  @override
  Future<void> requestPermissions() async {
    // Accessibility permission on macOS must be granted in
    // System Settings > Privacy & Security > Accessibility.
    // Deep-linking into the pane is done via `open` shell command.
    if (Platform.isMacOS) {
      await Process.run('open', [
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
      ]);
    }
  }

  @override
  void setTargetDisplay(DisplayInfo? display) => _target = display;

  @override
  Future<ScreenInfoEvent> screenInfo() async {
    if (!Platform.isMacOS) {
      return ScreenInfoEvent(width: 0, height: 0, scale: 1.0);
    }
    final t = _target;
    if (t != null) {
      return ScreenInfoEvent(width: t.width, height: t.height, scale: t.scale);
    }
    final id = _mainDisplay();
    return ScreenInfoEvent(
      width: _displayWide(id),
      height: _displayHigh(id),
      scale: 1.0,
    );
  }

  @override
  Future<void> handle(InputEvent event) async {
    if (!Platform.isMacOS) return;
    if (event is MouseMoveEvent) {
      _mouseEvent(kCGEventMouseMoved, kCGMouseButtonLeft, event.x, event.y);
    } else if (event is MouseButtonEvent) {
      _handleMouseButton(event);
    } else if (event is MouseWheelEvent) {
      _wheelEvent(event);
    } else if (event is KeyInputEvent) {
      _keyEvent(event);
    } else if (event is TextEvent) {
      for (final c in event.text.runes) {
        _sendUnicode(c);
      }
    }
  }

  // ---- helpers ----

  ({double x, double y}) _denormalize(double nx, double ny) {
    final t = _target;
    if (t != null) {
      return (
        x: t.x.toDouble() + nx.clamp(0.0, 1.0) * t.width,
        y: t.y.toDouble() + ny.clamp(0.0, 1.0) * t.height,
      );
    }
    final id = _mainDisplay();
    final w = _displayWide(id);
    final h = _displayHigh(id);
    return (x: nx.clamp(0.0, 1.0) * w, y: ny.clamp(0.0, 1.0) * h);
  }

  void _mouseEvent(int type, int button, double nx, double ny) {
    final pos = _denormalize(nx, ny);
    final pt = calloc<CGPoint>();
    try {
      pt.ref.x = pos.x;
      pt.ref.y = pos.y;
      final e = _createMouse(0, type, pt.ref, button);
      if (e != 0) {
        _post(kCGHIDEventTap, e);
        _release(e);
      }
    } finally {
      calloc.free(pt);
    }
  }

  void _handleMouseButton(MouseButtonEvent event) {
    final (int down, int up, int btn) = switch (event.button) {
      MouseButton.left => (
        kCGEventLeftMouseDown,
        kCGEventLeftMouseUp,
        kCGMouseButtonLeft,
      ),
      MouseButton.right => (
        kCGEventRightMouseDown,
        kCGEventRightMouseUp,
        kCGMouseButtonRight,
      ),
      MouseButton.middle => (
        kCGEventOtherMouseDown,
        kCGEventOtherMouseUp,
        kCGMouseButtonCenter,
      ),
    };
    _mouseEvent(event.down ? down : up, btn, event.x, event.y);
  }

  void _wheelEvent(MouseWheelEvent event) {
    // CGCreateScrollWheelEvent takes (src, unit, wheelCount, scroll1, ...)
    // scroll1 is vertical (positive = up), scroll2 is horizontal.
    final v = (event.dy * 3).round();
    final h = (event.dx * 3).round();
    final e = _createScroll(0, kCGScrollEventUnitLine, 2, v);
    if (e != 0) {
      _setInt(e, 12 /* kCGScrollWheelEventDeltaAxis2 */, h);
      _post(kCGHIDEventTap, e);
      _release(e);
    }
  }

  void _keyEvent(KeyInputEvent event) {
    final mapped = macKeyCodeFromHid(event.physicalKey);
    if (mapped == null) return;

    // Sync CapsLock before the keystroke.
    if (event.down) {
      final curCaps = (_flags & kCGEventFlagMaskAlphaShift) != 0;
      if (curCaps != event.capsLock) {
        if (event.capsLock) {
          _flags |= kCGEventFlagMaskAlphaShift;
        } else {
          _flags &= ~kCGEventFlagMaskAlphaShift;
        }
      }
    }

    final e = _createKey(0, mapped, event.down);
    if (e != 0) {
      _setInt(e, kCGKeyboardEventKeycode, mapped);
      _setFlags(e, _flags);
      _post(kCGHIDEventTap, e);
      _release(e);
    }
  }

  void _sendUnicode(int codePoint) {
    // No reliable public CG API to send arbitrary Unicode without going through
    // the key-mapping layer. Use UniChar trick: set keycode=0, let macOS
    // handle the character via the keyboard event Unicode field if available.
    // For now, skip unmapped characters gracefully.
  }
}
