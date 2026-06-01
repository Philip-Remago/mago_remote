import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/gestures.dart';

import '../protocol/input_event.dart' as proto;

/// Callback shape used by [GestureTranslator] to emit wire events.
typedef GestureSend = void Function(proto.InputEvent event, {bool reliable});

/// Schedules a one-shot timer; injectable so tests can drive it with
/// `fake_async` instead of real wall-clock waits.
typedef GestureTimerFactory =
    Timer Function(Duration delay, void Function() callback);

/// Translates raw [PointerEvent]s coming out of the controller's render
/// surface into wire-level input events for the host.
///
/// Two output modes, picked per-event from `hostNativeTouch`:
///
///   * **Native-touch hosts (Android)** — fingers and mouse alike are
///     forwarded as `TouchDown/Move/Up`. Mouse becomes a single
///     synthetic finger (id [_kMouseFingerId]); Ctrl+drag becomes two
///     synthetic fingers (`±_kTwoFingerOffsetPx` around the cursor) for
///     OS gestures like the recent-apps swipe; wheel becomes a
///     persistent scroll-finger that lifts on idle so Android can
///     compute fling velocity; Ctrl+wheel pinches.
///
///   * **Desktop hosts** — events go through the legacy mouse/key path
///     (`MouseButton`, `MouseMove`, `MouseWheel`). Touches on the
///     controller still get the long-press → right-click and drag
///     promotion behaviour.
///
/// Synthetic-finger pointer ids are negative so they can never collide
/// with real Flutter [PointerEvent.pointer] ids (which are always
/// positive monotonic).
class GestureTranslator {
  GestureTranslator({required this.send, GestureTimerFactory? timerFactory})
    : _timerFactory = timerFactory ?? Timer.new;

  final GestureSend send;
  final GestureTimerFactory _timerFactory;

  // Reserved synthetic pointer ids (always negative).
  static const int _kMouseFingerId = -1;
  static const int _kPinchFingerA = -10;
  static const int _kPinchFingerB = -11;
  static const int _kTwoFingerA = -20;
  static const int _kTwoFingerB = -21;
  static const int _kWheelFingerId = -30;

  // Multi-touch geometry.
  /// Half-distance between the two synthetic fingers used for
  /// Ctrl+drag (two-finger swipe), in normalized [0..1] host space.
  /// 0.04 ≈ 40 host px on a 1000 px-wide display.
  static const double _kTwoFingerOffsetN = 0.04;

  /// Initial half-distance between the two synthetic pinch fingers,
  /// normalized.
  static const double _kPinchInitialOffsetN = 0.06;

  /// Per wheel notch, how far (normalized) each pinch finger moves
  /// outward (zoom in) or inward (zoom out).
  static const double _kPinchStepN = 0.012;

  /// Per wheel notch, how far (normalized) the scroll-finger moves.
  /// Larger = each notch scrolls more host content.
  static const double _kWheelStepN = 0.06;

  /// Idle delay after the last wheel/pinch input before we lift the
  /// synthetic finger(s). Long enough that consecutive notches stitch
  /// into one stroke; short enough that the host's fling detector still
  /// sees the lift as "while moving".
  static const Duration _kWheelIdleLift = Duration(milliseconds: 150);

  /// Long-press threshold for touch → right-click on desktop hosts.
  static const Duration _kLongPressDelay = Duration(milliseconds: 500);

  /// Minimum drag distance (squared, in controller px²) before a touch
  /// is promoted from "tap" to "drag" on desktop hosts.
  static const double _kDragSlopSqPx = 12 * 12;

  // ----------------------------------------------------------------- state
  final Map<int, _PointerState> _pointers = {};
  _WheelGesture? _wheel;
  _PinchGesture? _pinch;

  // Double-tap tracking for touchEmulatesMouse.
  DateTime? _lastTapTime;
  Offset? _lastTapNorm;

  /// Max time between two taps to qualify as a double-click (ms).
  static const int _kDoubleTapMs = 400;

  /// Max distance (normalized, squared) between two taps to qualify.
  /// 0.02 ≈ 20 px on a 1000 px-wide screen.
  static const double _kDoubleTapDistSq = 0.02 * 0.02;

  /// Drop all in-flight gestures. Call when the session disconnects so
  /// pointers don't get stuck on the host.
  void reset() {
    for (final p in _pointers.values) {
      p.longPressTimer?.cancel();
    }
    _pointers.clear();
    _wheel?.idleTimer.cancel();
    _wheel = null;
    _pinch?.idleTimer.cancel();
    _pinch = null;
    _lastTapTime = null;
    _lastTapNorm = null;
  }

  void cancelAll() {
    final keys = List<int>.from(_pointers.keys);
    for (final pointer in keys) {
      _completePointer(
        pointer: pointer,
        buttons: 0,
        hostPoint: null,
        cancel: true,
      );
    }
    _wheel?.idleTimer.cancel();
    _wheel = null;
    _pinch?.idleTimer.cancel();
    _pinch = null;
    _lastTapTime = null;
    _lastTapNorm = null;
  }

  // ------------------------------------------------------------ pointer in
  void onPointerDown({
    required PointerDownEvent event,
    required Offset hostPoint,
    required bool hostNativeTouch,
    required bool isControlPressed,
  }) {
    final kind = event.kind;

    // ---- Real finger on the controller -------------------------------
    if (kind == PointerDeviceKind.touch) {
      if (hostNativeTouch) {
        // Forward the physical finger 1:1.
        _pointers[event.pointer] = _PointerState(
          start: event.localPosition,
          startNorm: hostPoint,
          flavor: _Flavor.realFingerNative,
        );
        send(
          proto.TouchDownEvent(
            id: event.pointer,
            x: hostPoint.dx,
            y: hostPoint.dy,
          ),
        );
        return;
      }
      // Touch-on-desktop: defer until we know tap vs drag vs long-press.
      final st = _PointerState(
        start: event.localPosition,
        startNorm: hostPoint,
        flavor: _Flavor.touchEmulatesMouse,
      );
      _pointers[event.pointer] = st;
      st.longPressTimer = _timerFactory(_kLongPressDelay, () {
        st.longPressFired = true;
        send(
          proto.MouseButtonEvent(
            button: proto.MouseButton.right,
            down: true,
            x: hostPoint.dx,
            y: hostPoint.dy,
          ),
        );
        send(
          proto.MouseButtonEvent(
            button: proto.MouseButton.right,
            down: false,
            x: hostPoint.dx,
            y: hostPoint.dy,
          ),
        );
      });
      return;
    }

    // ---- Mouse / stylus on the controller ----------------------------
    final isPrimary =
        (event.buttons & kPrimaryMouseButton) != 0
        // PointerDownEvent.buttons is sometimes 0 on the actual down
        // edge for a primary click; assume primary unless another bit
        // is set.
        ||
        event.buttons == 0 ||
        event.buttons == kPrimaryMouseButton;
    final isSecondary = (event.buttons & kSecondaryMouseButton) != 0;
    final isMiddle = (event.buttons & kMiddleMouseButton) != 0;

    if (hostNativeTouch) {
      // Right/middle have no analog on a touchscreen — drop silently
      // so the host doesn't see jitter or stuck buttons.
      if (isSecondary || isMiddle) {
        _pointers[event.pointer] = _PointerState(
          start: event.localPosition,
          startNorm: hostPoint,
          flavor: _Flavor.silentDrop,
        );
        return;
      }
      if (isControlPressed) {
        // Two-finger gesture (e.g. recents/app-switcher swipe).
        final a = Offset(
          (hostPoint.dx - _kTwoFingerOffsetN).clamp(0.0, 1.0),
          hostPoint.dy.clamp(0.0, 1.0),
        );
        final b = Offset(
          (hostPoint.dx + _kTwoFingerOffsetN).clamp(0.0, 1.0),
          hostPoint.dy.clamp(0.0, 1.0),
        );
        _pointers[event.pointer] = _PointerState(
          start: event.localPosition,
          startNorm: hostPoint,
          flavor: _Flavor.mouseTwoFinger,
          fingerA: a,
          fingerB: b,
        );
        send(proto.TouchDownEvent(id: _kTwoFingerA, x: a.dx, y: a.dy));
        send(proto.TouchDownEvent(id: _kTwoFingerB, x: b.dx, y: b.dy));
        return;
      }
      // Single synthetic finger.
      _pointers[event.pointer] = _PointerState(
        start: event.localPosition,
        startNorm: hostPoint,
        flavor: _Flavor.mouseSingleFinger,
      );
      send(
        proto.TouchDownEvent(
          id: _kMouseFingerId,
          x: hostPoint.dx,
          y: hostPoint.dy,
        ),
      );
      return;
    }

    // Desktop host: classic mouse path.
    _pointers[event.pointer] = _PointerState(
      start: event.localPosition,
      startNorm: hostPoint,
      flavor: _Flavor.mouseDesktop,
    );
    send(
      proto.MouseButtonEvent(
        button: _mapButton(isSecondary, isMiddle, isPrimary),
        down: true,
        x: hostPoint.dx,
        y: hostPoint.dy,
      ),
    );
  }

  void onPointerMove({
    required PointerMoveEvent event,
    required Offset hostPoint,
    required bool hostNativeTouch,
  }) {
    final st = _pointers[event.pointer];
    if (st == null) {
      // Move without prior down — ignore (cursor-tracking via hover
      // is handled separately by the caller).
      return;
    }
    switch (st.flavor) {
      case _Flavor.realFingerNative:
        send(
          proto.TouchMoveEvent(
            id: event.pointer,
            x: hostPoint.dx,
            y: hostPoint.dy,
          ),
          reliable: false,
        );
        return;
      case _Flavor.touchEmulatesMouse:
        if (st.longPressFired) return;
        if (!st.dragging) {
          final dx = event.localPosition.dx - st.start.dx;
          final dy = event.localPosition.dy - st.start.dy;
          if ((dx * dx + dy * dy) > _kDragSlopSqPx) {
            st.longPressTimer?.cancel();
            st.dragging = true;
            send(
              proto.MouseButtonEvent(
                button: proto.MouseButton.left,
                down: true,
                x: st.startNorm.dx,
                y: st.startNorm.dy,
              ),
            );
          }
        }
        send(
          proto.MouseMoveEvent(x: hostPoint.dx, y: hostPoint.dy),
          reliable: false,
        );
        return;
      case _Flavor.mouseSingleFinger:
        send(
          proto.TouchMoveEvent(
            id: _kMouseFingerId,
            x: hostPoint.dx,
            y: hostPoint.dy,
          ),
          reliable: false,
        );
        return;
      case _Flavor.mouseTwoFinger:
        // Translate both fingers by the same delta as the cursor.
        final dx = hostPoint.dx - st.startNorm.dx;
        final dy = hostPoint.dy - st.startNorm.dy;
        final a = Offset(
          (st.fingerA!.dx + dx).clamp(0.0, 1.0),
          (st.fingerA!.dy + dy).clamp(0.0, 1.0),
        );
        final b = Offset(
          (st.fingerB!.dx + dx).clamp(0.0, 1.0),
          (st.fingerB!.dy + dy).clamp(0.0, 1.0),
        );
        send(
          proto.TouchMoveEvent(id: _kTwoFingerA, x: a.dx, y: a.dy),
          reliable: false,
        );
        send(
          proto.TouchMoveEvent(id: _kTwoFingerB, x: b.dx, y: b.dy),
          reliable: false,
        );
        return;
      case _Flavor.mouseDesktop:
        send(
          proto.MouseMoveEvent(x: hostPoint.dx, y: hostPoint.dy),
          reliable: false,
        );
        return;
      case _Flavor.silentDrop:
        return;
    }
  }

  void onPointerUp({
    required PointerUpEvent event,
    required Offset? hostPoint,
    required bool hostNativeTouch,
  }) {
    _completePointer(
      pointer: event.pointer,
      buttons: event.buttons,
      hostPoint: hostPoint,
      cancel: false,
    );
  }

  void onPointerCancel({required PointerCancelEvent event}) {
    _completePointer(
      pointer: event.pointer,
      buttons: 0,
      hostPoint: null,
      cancel: true,
    );
  }

  void _completePointer({
    required int pointer,
    required int buttons,
    required Offset? hostPoint,
    required bool cancel,
  }) {
    final st = _pointers.remove(pointer);
    if (st == null) return;
    st.longPressTimer?.cancel();
    final lift = hostPoint ?? st.startNorm;

    switch (st.flavor) {
      case _Flavor.realFingerNative:
        send(
          proto.TouchUpEvent(
            id: pointer,
            x: lift.dx,
            y: lift.dy,
            cancel: cancel,
          ),
        );
        return;
      case _Flavor.touchEmulatesMouse:
        if (st.longPressFired) return; // right-click already sent
        if (st.dragging) {
          send(
            proto.MouseButtonEvent(
              button: proto.MouseButton.left,
              down: false,
              x: lift.dx,
              y: lift.dy,
            ),
          );
          _lastTapTime = null;
          _lastTapNorm = null;
        } else if (!cancel) {
          final now = DateTime.now();
          final prev = _lastTapTime;
          final prevPos = _lastTapNorm;
          final dx = st.startNorm.dx - (prevPos?.dx ?? 0);
          final dy = st.startNorm.dy - (prevPos?.dy ?? 0);
          final isDoubleTap =
              prev != null &&
              prevPos != null &&
              now.difference(prev).inMilliseconds < _kDoubleTapMs &&
              (dx * dx + dy * dy) < _kDoubleTapDistSq;

          if (isDoubleTap) {
            // Send all four events in one burst so they arrive at the host
            // within milliseconds — guarantees Windows registers a double-click
            // regardless of network latency between individual taps.
            _lastTapTime = null;
            _lastTapNorm = null;
            for (final down in [true, false, true, false]) {
              send(
                proto.MouseButtonEvent(
                  button: proto.MouseButton.left,
                  down: down,
                  x: st.startNorm.dx,
                  y: st.startNorm.dy,
                ),
              );
            }
          } else {
            _lastTapTime = now;
            _lastTapNorm = st.startNorm;
            send(
              proto.MouseButtonEvent(
                button: proto.MouseButton.left,
                down: true,
                x: st.startNorm.dx,
                y: st.startNorm.dy,
              ),
            );
            send(
              proto.MouseButtonEvent(
                button: proto.MouseButton.left,
                down: false,
                x: st.startNorm.dx,
                y: st.startNorm.dy,
              ),
            );
          }
        }
        return;
      case _Flavor.mouseSingleFinger:
        send(
          proto.TouchUpEvent(
            id: _kMouseFingerId,
            x: lift.dx,
            y: lift.dy,
            cancel: cancel,
          ),
        );
        return;
      case _Flavor.mouseTwoFinger:
        // Lift both fingers at their last positions.
        final dx = lift.dx - st.startNorm.dx;
        final dy = lift.dy - st.startNorm.dy;
        final a = Offset(
          (st.fingerA!.dx + dx).clamp(0.0, 1.0),
          (st.fingerA!.dy + dy).clamp(0.0, 1.0),
        );
        final b = Offset(
          (st.fingerB!.dx + dx).clamp(0.0, 1.0),
          (st.fingerB!.dy + dy).clamp(0.0, 1.0),
        );
        send(
          proto.TouchUpEvent(
            id: _kTwoFingerA,
            x: a.dx,
            y: a.dy,
            cancel: cancel,
          ),
        );
        send(
          proto.TouchUpEvent(
            id: _kTwoFingerB,
            x: b.dx,
            y: b.dy,
            cancel: cancel,
          ),
        );
        return;
      case _Flavor.mouseDesktop:
        send(
          proto.MouseButtonEvent(
            button: _mapButton(
              (buttons & kSecondaryMouseButton) != 0,
              (buttons & kMiddleMouseButton) != 0,
              true,
            ),
            down: false,
            x: lift.dx,
            y: lift.dy,
          ),
        );
        return;
      case _Flavor.silentDrop:
        return;
    }
  }

  // ------------------------------------------------------------- wheel in
  void onPointerSignal({
    required PointerSignalEvent event,
    required Offset hostPoint,
    required bool hostNativeTouch,
    required bool isControlPressed,
  }) {
    if (event is! PointerScrollEvent) return;
    if (!hostNativeTouch) {
      // Desktop host: legacy wheel event.
      send(
        proto.MouseWheelEvent(
          dx: -event.scrollDelta.dx / 50,
          dy: -event.scrollDelta.dy / 50,
        ),
      );
      return;
    }

    // Convert the framework's pixel-delta into a small notch count. One
    // wheel click on most mice is 100..120 px; round to at least 1 in
    // the dominant axis so a tiny scroll still produces visible motion.
    final notches = -event.scrollDelta.dy / 50;

    if (isControlPressed) {
      _pumpPinch(hostPoint, notches);
    } else {
      _pumpWheel(hostPoint, notches);
    }
  }

  void _pumpWheel(Offset cursor, double notches) {
    var w = _wheel;
    if (w == null) {
      // Begin a fresh scroll-finger at the cursor.
      w = _WheelGesture(
        anchor: cursor,
        idleTimer: _timerFactory(_kWheelIdleLift, _liftWheel),
      );
      _wheel = w;
      send(
        proto.TouchDownEvent(id: _kWheelFingerId, x: cursor.dx, y: cursor.dy),
      );
    } else {
      w.idleTimer.cancel();
      w.idleTimer = _timerFactory(_kWheelIdleLift, _liftWheel);
    }
    // Scroll-up (positive notches) = content drags down = finger moves
    // down. Y grows downward in normalized space.
    w.accumY = (w.accumY + notches * _kWheelStepN).clamp(-1.0, 1.0);
    final y = (w.anchor.dy + w.accumY).clamp(0.0, 1.0);
    send(
      proto.TouchMoveEvent(id: _kWheelFingerId, x: w.anchor.dx, y: y),
      reliable: false,
    );
  }

  void _liftWheel() {
    final w = _wheel;
    if (w == null) return;
    final y = (w.anchor.dy + w.accumY).clamp(0.0, 1.0);
    send(proto.TouchUpEvent(id: _kWheelFingerId, x: w.anchor.dx, y: y));
    _wheel = null;
  }

  void _pumpPinch(Offset cursor, double notches) {
    var p = _pinch;
    if (p == null) {
      final ax = (cursor.dx - _kPinchInitialOffsetN).clamp(0.0, 1.0);
      final bx = (cursor.dx + _kPinchInitialOffsetN).clamp(0.0, 1.0);
      final y = cursor.dy.clamp(0.0, 1.0);
      p = _PinchGesture(
        anchor: cursor,
        offsetA: Offset(ax, y),
        offsetB: Offset(bx, y),
        idleTimer: _timerFactory(_kWheelIdleLift, _liftPinch),
      );
      _pinch = p;
      send(proto.TouchDownEvent(id: _kPinchFingerA, x: ax, y: y));
      send(proto.TouchDownEvent(id: _kPinchFingerB, x: bx, y: y));
    } else {
      p.idleTimer.cancel();
      p.idleTimer = _timerFactory(_kWheelIdleLift, _liftPinch);
    }
    // Positive notches (scroll up) = spread = zoom in.
    final step = notches * _kPinchStepN;
    final ax = (p.offsetA.dx - step).clamp(0.0, 1.0);
    final bx = (p.offsetB.dx + step).clamp(0.0, 1.0);
    final y = p.offsetA.dy;
    p.offsetA = Offset(ax, y);
    p.offsetB = Offset(bx, y);
    send(
      proto.TouchMoveEvent(id: _kPinchFingerA, x: ax, y: y),
      reliable: false,
    );
    send(
      proto.TouchMoveEvent(id: _kPinchFingerB, x: bx, y: y),
      reliable: false,
    );
  }

  void _liftPinch() {
    final p = _pinch;
    if (p == null) return;
    send(
      proto.TouchUpEvent(id: _kPinchFingerA, x: p.offsetA.dx, y: p.offsetA.dy),
    );
    send(
      proto.TouchUpEvent(id: _kPinchFingerB, x: p.offsetB.dx, y: p.offsetB.dy),
    );
    _pinch = null;
  }

  static proto.MouseButton _mapButton(
    bool secondary,
    bool middle,
    bool primary,
  ) {
    if (secondary) return proto.MouseButton.right;
    if (middle) return proto.MouseButton.middle;
    return proto.MouseButton.left;
  }
}

enum _Flavor {
  /// Real finger forwarded as `TouchDown/Move/Up` to a touch host.
  realFingerNative,

  /// Real finger on a desktop host: tap→click, drag→left-drag, hold→right-click.
  touchEmulatesMouse,

  /// Mouse on a touch host without Ctrl: one synthetic finger.
  mouseSingleFinger,

  /// Mouse on a touch host with Ctrl: two synthetic fingers tracking the cursor.
  mouseTwoFinger,

  /// Mouse on a desktop host: classic `MouseButton`/`MouseMove`.
  mouseDesktop,

  /// Right/middle button on a touch host — no-op (drop on Up too).
  silentDrop,
}

class _PointerState {
  _PointerState({
    required this.start,
    required this.startNorm,
    required this.flavor,
    this.fingerA,
    this.fingerB,
  });
  final Offset start;
  final Offset startNorm;
  final _Flavor flavor;

  /// Initial position of synthetic finger A (two-finger / pinch). Null
  /// for single-finger flavors.
  final Offset? fingerA;
  final Offset? fingerB;
  Timer? longPressTimer;
  bool dragging = false;
  bool longPressFired = false;
}

class _WheelGesture {
  _WheelGesture({required this.anchor, required this.idleTimer});
  final Offset anchor;
  Timer idleTimer;
  double accumY = 0.0;
}

class _PinchGesture {
  _PinchGesture({
    required this.anchor,
    required this.offsetA,
    required this.offsetB,
    required this.idleTimer,
  });
  final Offset anchor;
  Offset offsetA;
  Offset offsetB;
  Timer idleTimer;
}
