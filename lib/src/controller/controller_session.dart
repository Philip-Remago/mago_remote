import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

import '../livekit/room_session.dart';
import '../protocol/input_event.dart' as proto;

/// Metadata about the host's active display, sent by the host as a
/// [proto.ScreenInfoEvent] whenever it starts sharing or a new controller
/// joins.
class HostScreenInfo {
  const HostScreenInfo({
    required this.width,
    required this.height,
    required this.nativeTouch,
  });

  /// Host display width in physical pixels.
  final int width;

  /// Host display height in physical pixels.
  final int height;

  /// True when the host can accept raw touch events (TouchDown / Move / Up)
  /// instead of synthesized mouse pairs. Always true for Android hosts; false
  /// for Windows / macOS / Linux hosts.
  final bool nativeTouch;
}

/// Lifecycle state of a [ControllerSession].
enum ControllerState { disconnected, connecting, connected, error }

/// Pure-logic session object for the controller (viewer) role.
///
/// The consuming app is responsible for:
/// 1. Obtaining a LiveKit JWT (use [package:mago_remote/mago_remote.dart]'s
///    [TokenClient]).
/// 2. Calling [connect] with the URL and token.
/// 3. Passing `this` to a [RemoteVideoView] widget (or subscribing to
///    [videoTrackStream] / [hostInfoStream] directly if building custom UI).
/// 4. Calling [dispose] in the widget's `dispose()`.
///
/// All streams are broadcast streams — multiple listeners are safe.
class ControllerSession {
  ControllerSession() : _roomSession = RoomSession();

  final RoomSession _roomSession;
  EventsListener<RoomEvent>? _listener;

  // ---- State streams ----
  final _stateCtl = StreamController<ControllerState>.broadcast();
  final _videoTrackCtl = StreamController<VideoTrack?>.broadcast();
  final _hostInfoCtl = StreamController<HostScreenInfo>.broadcast();
  final _imeStateCtl = StreamController<bool>.broadcast();
  final _displaysCtl = StreamController<proto.DisplaysInfoEvent>.broadcast();

  Stream<ControllerState> get stateStream => _stateCtl.stream;
  Stream<VideoTrack?> get videoTrackStream => _videoTrackCtl.stream;
  Stream<HostScreenInfo> get hostInfoStream => _hostInfoCtl.stream;

  /// Emits whenever the host advertises its list of available monitors
  /// (on controller-join and after every switch). Use [displays] /
  /// [activeSourceId] for the latest snapshot, and
  /// [requestSwitchDisplay] to ask the host to swap.
  Stream<proto.DisplaysInfoEvent> get displaysStream => _displaysCtl.stream;

  /// Emits `true` when the host reports an editable text field is focused,
  /// `false` when focus leaves it. Touch-platform controllers can use this
  /// to auto-show / auto-hide the soft keyboard.
  Stream<bool> get imeStateStream => _imeStateCtl.stream;

  // ---- Current-value accessors ----
  ControllerState _state = ControllerState.disconnected;
  VideoTrack? _currentVideoTrack;
  HostScreenInfo? _hostInfo;
  String? _lastError;
  List<proto.DisplayDescriptor> _displays = const [];
  String? _activeSourceId;

  ControllerState get state => _state;
  VideoTrack? get currentVideoTrack => _currentVideoTrack;
  int? get hostWidth => _hostInfo?.width;
  int? get hostHeight => _hostInfo?.height;
  bool get isNativeTouchHost => _hostInfo?.nativeTouch ?? false;
  bool get isConnected => _state == ControllerState.connected;
  String? get lastError => _lastError;

  /// Most recent list of monitors advertised by the host (empty until
  /// the host sends the first [proto.DisplaysInfoEvent], or on hosts
  /// running an older protocol version).
  List<proto.DisplayDescriptor> get displays => _displays;

  /// `DesktopCapturerSource.id` of the monitor the host is currently
  /// capturing, or null if unknown.
  String? get activeSourceId => _activeSourceId;

  // ---- API ----

  /// Connect to a LiveKit room. [liveKitUrl] is the wss:// URL and [token]
  /// is a JWT obtained from your token endpoint (e.g. via [TokenClient]).
  Future<void> connect({
    required String liveKitUrl,
    required String token,
  }) async {
    if (_state == ControllerState.connecting ||
        _state == ControllerState.connected) {
      return;
    }
    _setState(ControllerState.connecting);
    try {
      await _roomSession.connect(url: liveKitUrl, token: token);

      _listener = _roomSession.room.createListener();

      _listener!.on<RoomDisconnectedEvent>((e) {
        _currentVideoTrack = null;
        _videoTrackCtl.add(null);
        _setState(ControllerState.disconnected);
      });

      _listener!.on<RoomReconnectingEvent>((_) {
        _setState(ControllerState.connecting);
      });

      _listener!.on<RoomReconnectedEvent>((_) {
        _setState(ControllerState.connected);
      });

      _listener!.on<TrackSubscribedEvent>((e) {
        if (e.track is VideoTrack) {
          _currentVideoTrack = e.track as VideoTrack;
          _videoTrackCtl.add(_currentVideoTrack);
        }
      });

      _listener!.on<TrackUnsubscribedEvent>((e) {
        if (e.track is VideoTrack && e.track == _currentVideoTrack) {
          _currentVideoTrack = null;
          _videoTrackCtl.add(null);
          _setState(ControllerState.disconnected);
        }
      });

      _listener!.on<DataReceivedEvent>((e) {
        final ev = proto.InputEvent.decode(e.data);
        if (ev is proto.ScreenInfoEvent && ev.width > 0 && ev.height > 0) {
          _hostInfo = HostScreenInfo(
            width: ev.width,
            height: ev.height,
            nativeTouch: ev.nativeTouch,
          );
          _hostInfoCtl.add(_hostInfo!);
        } else if (ev is proto.ImeStateEvent) {
          _imeStateCtl.add(ev.open);
        } else if (ev is proto.DisplaysInfoEvent) {
          _displays = ev.displays;
          _activeSourceId = ev.activeSourceId;
          _displaysCtl.add(ev);
        }
      });

      // Pick up already-published video tracks from existing participants.
      for (final p in _roomSession.room.remoteParticipants.values) {
        for (final pub in p.videoTrackPublications) {
          final track = pub.track;
          if (track != null) {
            _currentVideoTrack = track as VideoTrack;
            _videoTrackCtl.add(_currentVideoTrack);
          }
        }
      }

      _setState(ControllerState.connected);
    } catch (e) {
      _lastError = e.toString();
      _setState(ControllerState.error);
    }
  }

  /// Disconnect from the room and reset all state.
  Future<void> disconnect() async {
    await _listener?.dispose();
    _listener = null;
    await _roomSession.dispose();
    _currentVideoTrack = null;
    _videoTrackCtl.add(null);
    _hostInfo = null;
    _displays = const [];
    _activeSourceId = null;
    _lastError = null;
    _setState(ControllerState.disconnected);
  }

  /// Send a wire-protocol event to the host.
  ///
  /// Silently dropped if the session is not connected. Pass
  /// `reliable: false` for high-frequency events (mouse moves, touch moves)
  /// so they go over the UDP data channel instead of the SCTP/reliable path.
  void sendEvent(proto.InputEvent event, {bool reliable = true}) {
    if (!isConnected) return;
    _roomSession.sendData(event.encode(), reliable: reliable);
  }

  /// Ask the host to start capturing the monitor with the given source id.
  /// [sourceId] must come from [displays] (a host-advertised
  /// [proto.DisplayDescriptor.sourceId]). No-ops if not connected.
  void requestSwitchDisplay(String sourceId) {
    sendEvent(proto.SwitchDisplayEvent(sourceId: sourceId), reliable: true);
  }

  /// Dispose all resources. Safe to call multiple times.
  Future<void> dispose() async {
    if (_state != ControllerState.disconnected) {
      await disconnect();
    }
    if (!_stateCtl.isClosed) await _stateCtl.close();
    if (!_videoTrackCtl.isClosed) await _videoTrackCtl.close();
    if (!_hostInfoCtl.isClosed) await _hostInfoCtl.close();
    if (!_imeStateCtl.isClosed) await _imeStateCtl.close();
    if (!_displaysCtl.isClosed) await _displaysCtl.close();
  }

  void _setState(ControllerState s) {
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }
}
