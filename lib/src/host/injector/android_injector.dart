import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';

/// Android host injector — bridges to a Kotlin AccessibilityService
/// via a MethodChannel (registered by [MagoRemotePlugin]).
///
/// Android does NOT allow non-system apps to inject raw key events, so:
///   • mouse moves/clicks are mapped to single-finger gestures via
///     AccessibilityService.dispatchGesture
///   • text input is sent through ACTION_SET_TEXT on the focused node
///   • dedicated keys (Back/Home/Recents) use performGlobalAction
class AndroidInjector implements InputInjector {
  static const _channel = MethodChannel('remote_desk/android_input');

  @override
  Future<bool> isReady() async {
    if (!Platform.isAndroid) return false;
    final res = await _channel.invokeMethod<bool>('isAccessibilityEnabled');
    return res ?? false;
  }

  @override
  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  @override
  void setTargetDisplay(DisplayInfo? display) {
    // Android injects through AccessibilityService gestures which target the
    // single foreground display only. Multi-display targeting is N/A.
  }

  @override
  Future<ScreenInfoEvent> screenInfo() async {
    if (!Platform.isAndroid) {
      return ScreenInfoEvent(width: 0, height: 0, scale: 1.0);
    }
    final m = await _channel.invokeMapMethod<String, dynamic>('screenInfo');
    return ScreenInfoEvent(
      width: (m?['w'] as num?)?.toInt() ?? 0,
      height: (m?['h'] as num?)?.toInt() ?? 0,
      scale: (m?['s'] as num?)?.toDouble() ?? 1.0,
      // Android can drive real held-finger gestures (tap, long-press,
      // drag, pinch) via AccessibilityService.dispatchGesture +
      // continueStroke — see GestureSession.kt. Tell the controller to
      // send raw TouchDown/Move/Up instead of synthesizing mouse pairs.
      nativeTouch: true,
    );
  }

  @override
  Future<void> handle(InputEvent event) async {
    if (!Platform.isAndroid) return;
    try {
      if (event is MouseMoveEvent) {
        // No-op: Android cursor is meaningless without a click. The Controller
        // should mostly send taps/swipes derived from pointer-down/up pairs.
        return;
      }
      if (event is MouseButtonEvent) {
        if (event.down) {
          await _channel.invokeMethod('tap', {'x': event.x, 'y': event.y});
        }
        return;
      }
      if (event is TouchDownEvent) {
        await _channel.invokeMethod('gestureBegin', {
          'id': event.id,
          'x': event.x,
          'y': event.y,
        });
        return;
      }
      if (event is TouchMoveEvent) {
        await _channel.invokeMethod('gestureMove', {
          'id': event.id,
          'x': event.x,
          'y': event.y,
        });
        return;
      }
      if (event is TouchUpEvent) {
        await _channel.invokeMethod('gestureEnd', {
          'id': event.id,
          'x': event.x,
          'y': event.y,
          'c': event.cancel,
        });
        return;
      }
      if (event is TextEvent) {
        await _channel.invokeMethod('setText', {'s': event.text});
        return;
      }
      if (event is KeyInputEvent && event.down) {
        // Special-case keys we *can* meaningfully service via the
        // accessibility API. Android security forbids injecting raw
        // KeyEvents to other apps, so anything not in this list is
        // dropped silently.
        const enterPhysical = 0x070028; // HID Enter
        const numpadEnterPhysical = 0x070058;
        const backspacePhysical = 0x07002A;
        if (event.physicalKey == backspacePhysical) {
          await _channel.invokeMethod('deleteBackward', {'n': 1});
          return;
        }
        if (event.physicalKey == enterPhysical ||
            event.physicalKey == numpadEnterPhysical) {
          // Trigger the editor's IME action (Search/Done/Send/Go) on
          // single-line fields, or insert a newline on multi-line ones.
          // Native imeAction handling is what actually submits a search
          // bar; splicing '\n' would just append a literal char.
          await _channel.invokeMethod('imeAction');
          return;
        }
        final action = _globalActionFor(event.physicalKey);
        if (action != null) {
          await _channel.invokeMethod('globalAction', {'a': action});
        }
      }
    } catch (e, st) {
      // Never let an injection failure (missing service, denied permission,
      // unsupported gesture) crash the host. Log and drop the event.
      // ignore: avoid_print
      print('AndroidInjector.handle failed: $e\n$st');
    }
  }

  /// Maps the HID physical-key usage code to Android
  /// `AccessibilityService.GLOBAL_ACTION_*` constants.
  int? _globalActionFor(int physicalKey) {
    switch (physicalKey) {
      case 0x070029: // Escape
        return 1; // GLOBAL_ACTION_BACK
      case 0x07004A: // Home
        return 2; // GLOBAL_ACTION_HOME
      case 0x07003A: // F1
        return 3; // GLOBAL_ACTION_RECENTS
      case 0x07003B: // F2
        return 4; // GLOBAL_ACTION_NOTIFICATIONS
      case 0x07003C: // F3
        return 5; // GLOBAL_ACTION_QUICK_SETTINGS
      case 0x07003D: // F4
        return 6; // GLOBAL_ACTION_POWER_DIALOG
      case 0x07003E: // F5
        return 8; // GLOBAL_ACTION_LOCK_SCREEN
    }
    return null;
  }
}
