import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';
import 'key_mapping.dart';

// Win32 mouse-wheel notch value.
const int _kWheelDelta = 120;

const int _kDedupMs = 30;

/// Windows host injector using the Win32 SendInput API via the `win32`
/// package (no hand-rolled FFI needed).
class WindowsInjector implements InputInjector {
  DisplayInfo? _target;

  void Function(String)? logger;

  final Map<String, DateTime> _lastSeen = {};

  @override
  Future<bool> isReady() async => Platform.isWindows;

  @override
  Future<void> requestPermissions() async {
    // Nothing to request; SendInput works for any user-level process.
    // NOTE: To control elevated windows, the host process itself must be
    // running elevated (UAC isolation).
  }

  @override
  void setTargetDisplay(DisplayInfo? display) {
    _target = display;
  }

  @override
  Future<ScreenInfoEvent> screenInfo() async {
    final t = _target;
    if (t != null) {
      return ScreenInfoEvent(width: t.width, height: t.height, scale: t.scale);
    }
    final w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    final h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    return ScreenInfoEvent(width: w, height: h, scale: 1.0);
  }

  bool _dedup(String key, String label) {
    final now = DateTime.now();
    final last = _lastSeen[key];
    if (last != null) {
      final deltaMs = now.difference(last).inMilliseconds;
      if (deltaMs < _kDedupMs) {
        logger?.call('[Injector] DEDUP $label (delta ${deltaMs}ms) — dropped');
        return true;
      }
    }
    _lastSeen[key] = now;
    return false;
  }

  @override
  Future<void> handle(InputEvent event) async {
    if (event is MouseMoveEvent) {
      _sendMouseAbsolute(event.x, event.y, MOUSEEVENTF_MOVE);
    } else if (event is MouseButtonEvent) {
      final label = 'mouse ${event.button.name} down=${event.down}';
      logger?.call('[Injector] $label');
      if (_dedup('m_${event.button.index}_${event.down ? 1 : 0}', label))
        return;
      final flag = _mouseButtonFlag(event.button, event.down);
      _sendMouseAbsolute(event.x, event.y, MOUSEEVENTF_MOVE | flag);
    } else if (event is MouseWheelEvent) {
      if (event.dy != 0) {
        _sendWheel(event.dy.round(), horizontal: false);
      }
      if (event.dx != 0) {
        _sendWheel(event.dx.round(), horizontal: true);
      }
    } else if (event is KeyInputEvent) {
      final label =
          'key physicalKey=0x${event.physicalKey.toRadixString(16)} down=${event.down}';
      logger?.call('[Injector] $label');
      if (_dedup('k_${event.physicalKey}_${event.down ? 1 : 0}', label)) return;
      _sendKey(event);
    } else if (event is TextEvent) {
      logger?.call('[Injector] text "${event.text}"');
      _sendText(event.text);
    }
  }

  // ---- helpers ----

  void _sendMouseAbsolute(double nx, double ny, int flags) {
    // Map normalized (0..1) into the virtual screen using
    // MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_ABSOLUTE which expects
    // coordinates 0..65535 spanning the *entire* virtual desktop.
    final vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
    final vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    final vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    final vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    final t = _target;
    final double px;
    final double py;
    if (t != null) {
      px = t.x + nx.clamp(0.0, 1.0) * t.width;
      py = t.y + ny.clamp(0.0, 1.0) * t.height;
    } else {
      px = vx + nx.clamp(0.0, 1.0) * vw;
      py = vy + ny.clamp(0.0, 1.0) * vh;
    }
    final x = (((px - vx) / (vw == 0 ? 1 : vw)) * 65535).round();
    final y = (((py - vy) / (vh == 0 ? 1 : vh)) * 65535).round();
    final pInput = calloc<INPUT>();
    try {
      pInput.ref.type = INPUT_MOUSE;
      pInput.ref.mi
        ..dx = x
        ..dy = y
        ..mouseData = 0
        ..dwFlags = flags | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK
        ..time = 0
        ..dwExtraInfo = 0;
      SendInput(1, pInput, sizeOf<INPUT>());
    } finally {
      calloc.free(pInput);
    }
  }

  int _mouseButtonFlag(MouseButton b, bool down) {
    switch (b) {
      case MouseButton.left:
        return down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
      case MouseButton.right:
        return down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
      case MouseButton.middle:
        return down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
    }
  }

  void _sendWheel(int delta, {required bool horizontal}) {
    final pInput = calloc<INPUT>();
    try {
      pInput.ref.type = INPUT_MOUSE;
      pInput.ref.mi
        ..dx = 0
        ..dy = 0
        ..mouseData = delta * _kWheelDelta
        ..dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL
        ..time = 0
        ..dwExtraInfo = 0;
      SendInput(1, pInput, sizeOf<INPUT>());
    } finally {
      calloc.free(pInput);
    }
  }

  void _sendKey(KeyInputEvent e) {
    // Reconcile CapsLock toggle BEFORE the keystroke so the host's caps
    // state matches the controller's.
    if (e.down) {
      final hostCaps = (GetKeyState(VK_CAPITAL) & 1) != 0;
      if (hostCaps != e.capsLock) {
        _tapVk(VK_CAPITAL, extended: false);
      }
    }

    final mapped = windowsKeyFromHid(e.physicalKey);
    final pInput = calloc<INPUT>();
    try {
      pInput.ref.type = INPUT_KEYBOARD;
      if (mapped != null) {
        pInput.ref.ki
          ..wVk = mapped.vk
          ..wScan = MapVirtualKey(mapped.vk, MAPVK_VK_TO_VSC)
          ..dwFlags =
              (mapped.extended ? KEYEVENTF_EXTENDEDKEY : 0) |
              (e.down ? 0 : KEYEVENTF_KEYUP)
          ..time = 0
          ..dwExtraInfo = 0;
      } else {
        pInput.ref.ki
          ..wVk = 0
          ..wScan = e.physicalKey & 0xFF
          ..dwFlags = KEYEVENTF_SCANCODE | (e.down ? 0 : KEYEVENTF_KEYUP)
          ..time = 0
          ..dwExtraInfo = 0;
      }
      SendInput(1, pInput, sizeOf<INPUT>());
    } finally {
      calloc.free(pInput);
    }
  }

  /// Press-and-release a single virtual key (used for CapsLock sync).
  void _tapVk(int vk, {required bool extended}) {
    final scan = MapVirtualKey(vk, MAPVK_VK_TO_VSC);
    for (final down in [true, false]) {
      final p = calloc<INPUT>();
      try {
        p.ref.type = INPUT_KEYBOARD;
        p.ref.ki
          ..wVk = vk
          ..wScan = scan
          ..dwFlags =
              (extended ? KEYEVENTF_EXTENDEDKEY : 0) |
              (down ? 0 : KEYEVENTF_KEYUP)
          ..time = 0
          ..dwExtraInfo = 0;
        SendInput(1, p, sizeOf<INPUT>());
      } finally {
        calloc.free(p);
      }
    }
  }

  void _sendText(String s) {
    for (final code in s.codeUnits) {
      for (final down in [true, false]) {
        final pInput = calloc<INPUT>();
        try {
          pInput.ref.type = INPUT_KEYBOARD;
          pInput.ref.ki
            ..wVk = 0
            ..wScan = code
            ..dwFlags = KEYEVENTF_UNICODE | (down ? 0 : KEYEVENTF_KEYUP)
            ..time = 0
            ..dwExtraInfo = 0;
          SendInput(1, pInput, sizeOf<INPUT>());
        } finally {
          calloc.free(pInput);
        }
      }
    }
  }
}
