import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show sqrt;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

import '../protocol/input_event.dart' as proto;
import 'controller_session.dart';
import 'gesture_translator.dart';
import 'ime_bridge.dart';

// ─────────────────────────────────────────────────────────────────────────────
// RemoteVideoViewController
// ─────────────────────────────────────────────────────────────────────────────

/// A controller that lets the consuming app inspect and toggle the soft
/// keyboard shown on top of [RemoteVideoView].
///
/// Typical usage — add a FAB to your Scaffold:
/// ```dart
/// final _controller = RemoteVideoViewController();
///
/// FloatingActionButton(
///   onPressed: _controller.toggleKeyboard,
///   child: ListenableBuilder(
///     listenable: _controller,
///     builder: (_, __) => Icon(
///       _controller.isKeyboardVisible
///           ? Icons.keyboard_hide
///           : Icons.keyboard,
///     ),
///   ),
/// )
/// ```
class RemoteVideoViewController extends ChangeNotifier {
  bool _keyboardVisible = false;

  /// Whether the soft keyboard is currently visible.
  bool get isKeyboardVisible => _keyboardVisible;

  // Callbacks wired by [_RemoteVideoViewState].
  void Function()? _onShow;
  void Function()? _onHide;

  /// Show the soft keyboard.
  void showKeyboard() => _onShow?.call();

  /// Hide the soft keyboard.
  void hideKeyboard() => _onHide?.call();

  /// Toggle the soft keyboard.
  void toggleKeyboard() => _keyboardVisible ? hideKeyboard() : showKeyboard();

  // ---- Internal API used by [_RemoteVideoViewState] ----

  void _attachCallbacks({
    required void Function() show,
    required void Function() hide,
  }) {
    _onShow = show;
    _onHide = hide;
  }

  void _detachCallbacks() {
    _onShow = null;
    _onHide = null;
  }

  void _setVisible(bool visible) {
    if (_keyboardVisible == visible) return;
    _keyboardVisible = visible;
    notifyListeners();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RemoteVideoView
// ─────────────────────────────────────────────────────────────────────────────

/// Full-surface widget that renders the host's screen and forwards pointer /
/// keyboard events back to the host via [session].
///
/// The consuming app places this as the `body` (or inside a Stack / Expanded)
/// and wraps it with whatever chrome (AppBar, FAB, etc.) it needs. All
/// session lifecycle management stays in the app; this widget is a pure
/// renderer + input forwarder.
///
/// ```dart
/// final _session = ControllerSession();
/// final _controller = RemoteVideoViewController();
///
/// // In build():
/// Scaffold(
///   appBar: AppBar(title: const Text('Remote')),
///   body: RemoteVideoView(session: _session, controller: _controller),
///   floatingActionButton: ListenableBuilder(
///     listenable: _controller,
///     builder: (_, __) => FloatingActionButton(
///       onPressed: _controller.toggleKeyboard,
///       child: Icon(_controller.isKeyboardVisible
///           ? Icons.keyboard_hide : Icons.keyboard),
///     ),
///   ),
/// )
/// ```
class RemoteVideoView extends StatefulWidget {
  const RemoteVideoView({
    super.key,
    required this.session,
    this.controller,
    this.backgroundColor = Colors.black,
    this.showBorder = true,
    this.showResetZoomButton = true,
    this.maxZoom = 5.0,
  });

  /// The active [ControllerSession] to subscribe video and forward events to.
  final ControllerSession session;

  /// Optional controller for keyboard visibility. If null, keyboard
  /// management is only driven by host ImeStateEvents (auto-show/hide on
  /// touch platforms).
  final RemoteVideoViewController? controller;

  /// Background color shown behind the video while the host hasn't sent a
  /// track yet, and in the letterbox bands once it has.
  final Color backgroundColor;

  /// Whether to draw a faint border around the video rect to show the user
  /// the tap-active area.
  final bool showBorder;

  /// Whether to show a reset-zoom button when zoomed in.
  final bool showResetZoomButton;

  /// Maximum pinch-zoom level. Default 5×.
  final double maxZoom;

  @override
  State<RemoteVideoView> createState() => _RemoteVideoViewState();
}

class _RemoteVideoViewState extends State<RemoteVideoView> {
  final _focusNode = FocusNode();
  late final ImeBridge _ime = ImeBridge(send: _send);
  late final GestureTranslator _gestures = GestureTranslator(send: _send);

  VideoTrack? _videoTrack;
  HostScreenInfo? _hostInfo;
  bool _imeOpen = false;

  // Subscriptions to ControllerSession streams.
  StreamSubscription<VideoTrack?>? _videoSub;
  StreamSubscription<HostScreenInfo>? _hostInfoSub;
  StreamSubscription<bool>? _imeSub;
  StreamSubscription<ControllerState>? _stateSub;

  // ---- Zoom / pan state ----
  double _zoomScale = 1.0;
  Offset _panOffset = Offset.zero;

  final Map<int, Offset> _activePointers = {};
  double? _pinchStartDist;
  double? _pinchStartScale;
  Offset? _pinchStartMid;
  Offset? _pinchStartPan;

  // Double-tap to reset zoom (touch only).
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  bool get _isTouchPlatform => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _subscribeSession();
    _wireController();
  }

  @override
  void didUpdateWidget(RemoteVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _unsubscribeSession();
      _subscribeSession();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detachCallbacks();
      _wireController();
    }
  }

  void _wireController() {
    widget.controller?._attachCallbacks(
      show: _showKeyboard,
      hide: _hideKeyboard,
    );
  }

  void _subscribeSession() {
    final s = widget.session;
    _videoSub = s.videoTrackStream.listen((track) {
      if (mounted) setState(() => _videoTrack = track);
      if (track != null) _focusNode.requestFocus();
    });
    _hostInfoSub = s.hostInfoStream.listen((info) {
      if (mounted) setState(() => _hostInfo = info);
    });
    _imeSub = s.imeStateStream.listen((open) {
      if (!_isTouchPlatform) return;
      if (open && !_imeOpen) {
        _showKeyboard();
      } else if (!open && _imeOpen) {
        _hideKeyboard();
      }
    });
    _stateSub = s.stateStream.listen((state) {
      if (state == ControllerState.connected) {
        _focusNode.requestFocus();
      }
      if (state == ControllerState.disconnected ||
          state == ControllerState.error) {
        _reset();
      }
    });

    // Sync current state if session is already connected.
    final current = s.currentVideoTrack;
    if (current != null && mounted) {
      setState(() => _videoTrack = current);
    }
  }

  void _unsubscribeSession() {
    _videoSub?.cancel();
    _hostInfoSub?.cancel();
    _imeSub?.cancel();
    _stateSub?.cancel();
    _videoSub = null;
    _hostInfoSub = null;
    _imeSub = null;
    _stateSub = null;
  }

  void _reset() {
    _ime.detach();
    _gestures.reset();
    _activePointers.clear();
    _pinchStartDist = null;
    _pinchStartScale = null;
    _pinchStartMid = null;
    _pinchStartPan = null;
    if (mounted) {
      setState(() {
        _videoTrack = null;
        _hostInfo = null;
        _imeOpen = false;
        _zoomScale = 1.0;
        _panOffset = Offset.zero;
      });
    }
    widget.controller?._setVisible(false);
  }

  @override
  void dispose() {
    widget.controller?._detachCallbacks();
    _unsubscribeSession();
    _ime.detach();
    _gestures.reset();
    _focusNode.dispose();
    super.dispose();
  }

  void _send(proto.InputEvent ev, {bool reliable = true}) {
    widget.session.sendEvent(ev, reliable: reliable);
  }

  void _showKeyboard() {
    _ime.attach();
    if (mounted) setState(() => _imeOpen = true);
    widget.controller?._setVisible(true);
  }

  void _hideKeyboard() {
    _ime.detach();
    if (mounted) setState(() => _imeOpen = false);
    widget.controller?._setVisible(false);
  }

  // ---- Geometry helpers ----

  /// Letterboxed rect occupied by the host video inside [container] at 1× zoom.
  Rect _videoRect(Size container) {
    final info = _hostInfo;
    if (info == null || info.width <= 0 || info.height <= 0) {
      return Offset.zero & container;
    }
    final cw = container.width;
    final ch = container.height;
    if (cw <= 0 || ch <= 0) return Offset.zero & container;
    final hostA = info.width / info.height;
    final contA = cw / ch;
    final double w, h;
    if (hostA > contA) {
      w = cw;
      h = cw / hostA;
    } else {
      h = ch;
      w = ch * hostA;
    }
    return Rect.fromLTWH((cw - w) / 2, (ch - h) / 2, w, h);
  }

  Offset? _toHost(Offset local, Rect rect, {bool strict = false}) {
    if (rect.width <= 0 || rect.height <= 0) return null;
    final nx = (local.dx - rect.left) / rect.width;
    final ny = (local.dy - rect.top) / rect.height;
    if (strict && (nx < 0 || nx > 1 || ny < 0 || ny > 1)) return null;
    return Offset(nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));
  }

  Offset? _toHostZoomed(Offset local, Rect rect, {bool strict = false}) {
    final center = rect.center;
    final unzoomed = (local - _panOffset - center) / _zoomScale + center;
    return _toHost(unzoomed, rect, strict: strict);
  }

  void _resetZoom() {
    setState(() {
      _zoomScale = 1.0;
      _panOffset = Offset.zero;
    });
  }

  Offset _clampPan(Offset pan, Rect videoRect) {
    if (_zoomScale <= 1.0) return Offset.zero;
    final maxX = videoRect.width * (_zoomScale - 1) / 2;
    final maxY = videoRect.height * (_zoomScale - 1) / 2;
    return Offset(pan.dx.clamp(-maxX, maxX), pan.dy.clamp(-maxY, maxY));
  }

  bool _isInsideActiveArea(Offset local, Rect videoRect, EdgeInsets gi) {
    if (!videoRect.contains(local)) return false;
    if (local.dx < gi.left) return false;
    final mq = MediaQuery.maybeOf(context);
    final fullW = mq?.size.width ?? videoRect.right;
    final fullH = mq?.size.height ?? videoRect.bottom;
    if (local.dx > fullW - gi.right) return false;
    if (local.dy > fullH - gi.bottom) return false;
    return true;
  }

  // ---- Key event ----

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) {
    final isDown = evt is KeyDownEvent || evt is KeyRepeatEvent;
    int mods = 0;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    if (keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight)) {
      mods |= proto.KeyMods.shift;
    }
    if (keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight)) {
      mods |= proto.KeyMods.ctrl;
    }
    if (keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight)) {
      mods |= proto.KeyMods.alt;
    }
    if (keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight)) {
      mods |= proto.KeyMods.meta;
    }
    final capsLock = HardwareKeyboard.instance.lockModesEnabled.contains(
      KeyboardLockMode.capsLock,
    );
    _send(
      proto.KeyInputEvent(
        logicalKey: evt.logicalKey.keyId,
        physicalKey: evt.physicalKey.usbHidUsage,
        down: isDown,
        modifiers: mods,
        capsLock: capsLock,
      ),
    );
    // Also forward text character for non-control keys on key-down.
    if (isDown &&
        evt.character != null &&
        evt.character!.isNotEmpty &&
        (mods &
                (proto.KeyMods.ctrl |
                    proto.KeyMods.meta |
                    proto.KeyMods.alt)) ==
            0) {
      final code = evt.character!.codeUnitAt(0);
      if (code >= 0x20 && code != 0x7f) {
        _send(proto.TextEvent(text: evt.character!));
      }
    }
    return KeyEventResult.handled;
  }

  // ---- Pointer handlers ----

  void _onHover(PointerHoverEvent e, Rect rect, EdgeInsets gi) {
    if (!_isInsideActiveArea(e.localPosition, rect, gi)) return;
    final n = _toHostZoomed(e.localPosition, rect, strict: true);
    if (n == null) return;
    _send(proto.MouseMoveEvent(x: n.dx, y: n.dy), reliable: false);
  }

  void _onPointerDown(PointerDownEvent e, Rect rect, EdgeInsets gi) {
    _activePointers[e.pointer] = e.localPosition;

    if (_activePointers.length >= 2) {
      if (_activePointers.length == 2) {
        _gestures.reset();
        final positions = _activePointers.values.toList();
        final dx = positions[1].dx - positions[0].dx;
        final dy = positions[1].dy - positions[0].dy;
        _pinchStartDist = sqrt(dx * dx + dy * dy);
        _pinchStartScale = _zoomScale;
        _pinchStartMid = Offset(
          (positions[0].dx + positions[1].dx) / 2,
          (positions[0].dy + positions[1].dy) / 2,
        );
        _pinchStartPan = _panOffset;
      }
      return;
    }

    // Double-tap to reset zoom (touch only).
    if (e.kind == PointerDeviceKind.touch) {
      final now = DateTime.now();
      final isDoubleTap =
          _lastTapTime != null &&
          _lastTapPosition != null &&
          now.difference(_lastTapTime!).inMilliseconds < 300 &&
          (e.localPosition - _lastTapPosition!).distanceSquared < 900;
      _lastTapTime = now;
      _lastTapPosition = e.localPosition;
      if (isDoubleTap && _zoomScale > 1.0) {
        _resetZoom();
        return;
      }
    }

    if (!_isInsideActiveArea(e.localPosition, rect, gi)) return;
    final n = _toHostZoomed(e.localPosition, rect, strict: true);
    if (n == null) return;
    _gestures.onPointerDown(
      event: e,
      hostPoint: n,
      hostNativeTouch: widget.session.isNativeTouchHost,
      isControlPressed: HardwareKeyboard.instance.isControlPressed,
    );
  }

  void _onPointerMove(PointerMoveEvent e, Rect rect, EdgeInsets gi) {
    _activePointers[e.pointer] = e.localPosition;

    if (_activePointers.length >= 2) {
      if (_activePointers.length == 2 && _pinchStartDist != null) {
        final positions = _activePointers.values.toList();
        final p0 = positions[0];
        final p1 = positions[1];
        final dx = p1.dx - p0.dx;
        final dy = p1.dy - p0.dy;
        final currentDist = sqrt(dx * dx + dy * dy);
        final currentMid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
        final newScale = (_pinchStartScale! * currentDist / _pinchStartDist!)
            .clamp(1.0, widget.maxZoom);
        final newPan = _clampPan(
          _pinchStartPan! + (currentMid - _pinchStartMid!),
          rect,
        );
        setState(() {
          _zoomScale = newScale;
          _panOffset = newPan;
        });
      }
      return;
    }

    final n = _toHostZoomed(e.localPosition, rect);
    if (n == null) return;
    _gestures.onPointerMove(
      event: e,
      hostPoint: n,
      hostNativeTouch: widget.session.isNativeTouchHost,
    );
  }

  void _onPointerUp(PointerUpEvent e, Rect rect, EdgeInsets gi) {
    final wasPinching = _activePointers.length >= 2;
    _activePointers.remove(e.pointer);

    if (wasPinching) {
      if (_activePointers.length < 2) {
        _pinchStartDist = null;
        _pinchStartScale = null;
        _pinchStartMid = null;
        _pinchStartPan = null;
      }
      return;
    }

    final n = _toHostZoomed(e.localPosition, rect);
    _gestures.onPointerUp(
      event: e,
      hostPoint: n,
      hostNativeTouch: widget.session.isNativeTouchHost,
    );
  }

  void _onPointerCancel(PointerCancelEvent e) {
    final wasPinching = _activePointers.length >= 2;
    _activePointers.remove(e.pointer);
    if (wasPinching) {
      if (_activePointers.length < 2) {
        _pinchStartDist = null;
        _pinchStartScale = null;
        _pinchStartMid = null;
        _pinchStartPan = null;
      }
      return;
    }
    _gestures.onPointerCancel(event: e);
  }

  void _onPointerSignal(PointerSignalEvent e, Rect rect, EdgeInsets gi) {
    if (e is! PointerScrollEvent) return;
    if (!_isInsideActiveArea(e.localPosition, rect, gi)) return;

    // Ctrl + scroll → local zoom at the cursor's focal point.
    if (HardwareKeyboard.instance.isControlPressed) {
      final dy = e.scrollDelta.dy;
      if (dy == 0) return;
      final oldScale = _zoomScale;
      final newScale = (_zoomScale * (1 - dy * 0.002)).clamp(
        1.0,
        widget.maxZoom,
      );
      if (newScale == oldScale) return;
      final focal = e.localPosition;
      final center = rect.center;
      final worldUnderCursor =
          (focal - _panOffset - center) / oldScale + center;
      final newPan = focal - (worldUnderCursor - center) * newScale - center;
      setState(() {
        _zoomScale = newScale;
        _panOffset = _clampPan(newPan, rect);
      });
      return;
    }

    // Plain scroll → forward to host.
    final n = _toHostZoomed(e.localPosition, rect, strict: true);
    if (n == null) return;
    _gestures.onPointerSignal(
      event: e,
      hostPoint: n,
      hostNativeTouch: widget.session.isNativeTouchHost,
      isControlPressed: false,
    );
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final gi = MediaQuery.of(context).systemGestureInsets;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fullSize = Size(constraints.maxWidth, constraints.maxHeight);
        final videoRect = _videoRect(fullSize);
        final video = _videoTrack;

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerHover: (e) => _onHover(e, videoRect, gi),
            onPointerDown: (e) => _onPointerDown(e, videoRect, gi),
            onPointerMove: (e) => _onPointerMove(e, videoRect, gi),
            onPointerUp: (e) => _onPointerUp(e, videoRect, gi),
            onPointerCancel: _onPointerCancel,
            onPointerSignal: (e) => _onPointerSignal(e, videoRect, gi),
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: Container(
                    color: widget.backgroundColor,
                    child: video == null
                        ? const Center(
                            child: Text(
                              'Waiting for host video…',
                              style: TextStyle(color: Colors.white70),
                            ),
                          )
                        : ClipRect(
                            child: Transform(
                              transform: Matrix4.identity()
                                ..translate(_panOffset.dx, _panOffset.dy)
                                ..scale(_zoomScale, _zoomScale),
                              alignment: Alignment.center,
                              child: VideoTrackRenderer(
                                video,
                                fit: VideoViewFit.contain,
                              ),
                            ),
                          ),
                  ),
                ),
                if (widget.showBorder && video != null && _hostInfo != null)
                  Positioned.fromRect(
                    rect: videoRect,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.showResetZoomButton &&
                    video != null &&
                    _zoomScale > 1.0)
                  Positioned(
                    top: videoRect.top + 8,
                    right: fullSize.width - videoRect.right + 8,
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      child: IconButton(
                        icon: const Icon(
                          Icons.zoom_out_map,
                          color: Colors.white,
                        ),
                        tooltip: 'Reset zoom',
                        onPressed: _resetZoom,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
