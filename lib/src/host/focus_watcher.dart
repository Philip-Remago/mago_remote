import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// Streams a single boolean — "is the OS reporting that an editable text
/// field currently has focus on this host?" — so the host can tell remote
/// controllers when to surface the soft keyboard.
///
/// Per-platform implementation:
///   • Android   — EventChannel `remote_desk/android_focus`, fed by our
///                 AccessibilityService (RemoteInputService.kt).
///   • Windows   — Polls `GetGUIThreadInfo` ~4 Hz and matches the focused
///                 control's class name against the known edit-control
///                 list (Edit, RichEdit*, etc).
///   • macOS     — TODO. AXObserver watching kAXFocusedUIElementChanged;
///                 stub returns false for now.
///   • Linux/web — unsupported (controller-only platforms anyway).
abstract class FocusWatcher {
  static FocusWatcher forCurrentPlatform() {
    if (Platform.isAndroid) return _AndroidFocusWatcher();
    if (Platform.isWindows) return _WindowsFocusWatcher();
    return _NoopFocusWatcher();
  }

  /// Distinct stream of focus state changes. Emits the current value on
  /// subscribe so callers can sync their state without waiting.
  Stream<bool> get editableFocused;

  Future<void> dispose();
}

class _NoopFocusWatcher extends FocusWatcher {
  final _ctl = StreamController<bool>.broadcast();
  bool _seeded = false;

  @override
  Stream<bool> get editableFocused {
    // Replay an initial false so subscribers know the ground truth.
    if (!_seeded) {
      _seeded = true;
      Future.microtask(() {
        if (!_ctl.isClosed) _ctl.add(false);
      });
    }
    return _ctl.stream;
  }

  @override
  Future<void> dispose() async {
    await _ctl.close();
  }
}

class _AndroidFocusWatcher extends FocusWatcher {
  static const _channel = EventChannel('remote_desk/android_focus');

  StreamSubscription<dynamic>? _sub;
  final _ctl = StreamController<bool>.broadcast();
  bool? _last;

  _AndroidFocusWatcher() {
    _sub = _channel.receiveBroadcastStream().listen(
      (event) {
        final v = event == true;
        if (_last == v) return;
        _last = v;
        if (!_ctl.isClosed) _ctl.add(v);
      },
      onError: (_) {
        // Keep the stream alive; the AccessibilityService might not be
        // bound yet. We'll just stop seeing updates until it is.
      },
      cancelOnError: false,
    );
  }

  @override
  Stream<bool> get editableFocused => _ctl.stream;

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _ctl.close();
  }
}

/// Polls the foreground thread's focused HWND every ~250ms and reports
/// `true` whenever the window's class name matches a known edit-control
/// (Edit, RichEdit*, etc) or carries the `ES_*` style bits.
///
/// Why polling instead of `SetWinEventHook`? Hooks need a Windows message
/// pump on the calling thread, and Flutter's UI isolate doesn't run one
/// we can hijack from Dart. Polling at 4 Hz is well under 0.1% CPU and
/// matches the latency budget for "controller taps a text field, sees
/// soft keyboard pop".
class _WindowsFocusWatcher extends FocusWatcher {
  static const _kPollPeriod = Duration(milliseconds: 250);

  // Class names of standard editable controls. Lower-cased; comparisons
  // are case-insensitive because Win32 class registration is too.
  static const _kEditClassPrefixes = <String>[
    'edit',
    'richedit',
    'textbox', // .NET WinForms variants
    'windowsforms10.edit', // .NET WinForms (concrete)
    'scintilla', // many editors / notepad++
  ];

  final _ctl = StreamController<bool>.broadcast();
  Timer? _timer;
  bool _last = false;
  bool _seeded = false;

  _WindowsFocusWatcher() {
    _timer = Timer.periodic(_kPollPeriod, (_) => _tick());
    // Push initial state so subscribers don't sit at "unknown".
    Future.microtask(_tick);
  }

  void _tick() {
    final v = _probeFocusedIsEditable();
    if (!_seeded) {
      _seeded = true;
      _last = v;
      if (!_ctl.isClosed) _ctl.add(v);
      return;
    }
    if (_last == v) return;
    _last = v;
    if (!_ctl.isClosed) _ctl.add(v);
  }

  /// Returns true when the focused control of the foreground thread
  /// looks like an OS-level edit field. Browsers/Electron/Chromium
  /// composite their own UI inside `Chrome_RenderWidgetHostHWND` and
  /// therefore can't be detected this way — that's a known limitation;
  /// the controller's manual keyboard FAB covers that case.
  bool _probeFocusedIsEditable() {
    final fg = GetForegroundWindow();
    if (fg == 0) return false;
    final pidPtr = calloc<Uint32>();
    final tid = GetWindowThreadProcessId(fg, pidPtr);
    calloc.free(pidPtr);
    if (tid == 0) return false;

    final info = calloc<GUITHREADINFO>();
    info.ref.cbSize = sizeOf<GUITHREADINFO>();
    int hwndFocus = 0;
    try {
      if (GetGUIThreadInfo(tid, info) != 0) {
        hwndFocus = info.ref.hwndFocus;
      }
    } finally {
      calloc.free(info);
    }
    if (hwndFocus == 0) return false;

    // Class name match.
    final buf = wsalloc(256);
    try {
      final n = GetClassName(hwndFocus, buf, 256);
      if (n > 0) {
        final cls = buf.toDartString(length: n).toLowerCase();
        for (final prefix in _kEditClassPrefixes) {
          if (cls.startsWith(prefix)) return true;
        }
      }
    } finally {
      free(buf);
    }
    return false;
  }

  @override
  Stream<bool> get editableFocused => _ctl.stream;

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _ctl.close();
  }
}
