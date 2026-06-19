import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import '../livekit/room_session.dart';
import '../protocol/input_event.dart';
import 'display_info.dart';
import 'focus_watcher.dart';
import 'injector/input_injector.dart';
import 'injector/windows_injector.dart';
import 'screen_enumerator.dart';

/// Lifecycle state of a [HostSession].
enum HostState { idle, starting, connected, error }

/// Target screen-share encode parameters: 936p (16:9) @ 60fps, 10 Mbps cap.
/// Bitrate/framerate here mirror the RTP `screenShareEncoding` in
/// [RoomSession]; the dimensions drive what the desktop capturer scales to.
const _screenShareParams = VideoParameters(
  description: 'screenShare936FPS60',
  dimensions: VideoDimensions(1664, 936),
  encoding: VideoEncoding(
    maxBitrate: 10 * 1000 * 1000,
    maxFramerate: 60,
  ),
);

/// Pure-logic session object for the host (screen-sharing) role.
///
/// The consuming app is responsible for:
/// 1. Obtaining a LiveKit JWT (use [TokenClient]).
/// 2. Calling [start] with the URL, token, and optionally a sourceId
///    (desktop only — leave null on Android/iOS).
/// 3. Displaying [pairingCode] so the controller can enter it.
/// 4. Calling [dispose] in the widget's `dispose()`.
///
/// All streams are broadcast streams — multiple listeners are safe.
class HostSession {
  static void Function(String)? onLog;

  HostSession()
    : _roomSession = RoomSession(),
      _injector = InputInjector.forCurrentPlatform(),
      _focusWatcher = FocusWatcher.forCurrentPlatform(),
      pairingCode = _generateCode() {
    if (_injector is WindowsInjector) {
      _injector.logger = (msg) => HostSession.onLog?.call(msg);
    }
  }

  final RoomSession _roomSession;
  final InputInjector _injector;
  final FocusWatcher _focusWatcher;
  EventsListener<RoomEvent>? _listener;
  StreamSubscription<bool>? _focusSub;
  bool _lastFocusBroadcast = false;

  /// Capture options resolved during [start]; reused when a controller
  /// joins and we lazily enable screen sharing.
  ScreenShareCaptureOptions? _screenOpts;

  /// True once we've called `setScreenShareEnabled(true)`.
  bool _capturing = false;

  /// Last enumerated `DesktopCapturerSource` list. Kept in sync with
  /// [_displays] (same length, same order) so the controller-facing
  /// `DisplayDescriptor.sourceId` lines up with what [switchSource]
  /// expects.
  List<rtc.DesktopCapturerSource> _lastSources = const [];

  /// The `DesktopCapturerSource.id` we're currently capturing, or null
  /// if not capturing yet.
  String? _activeSourceId;

  static const _androidChannel = MethodChannel('remote_desk/android_input');

  // ---- Public immutable fields ----

  /// 6-digit random pairing code. Display this to the user.
  final String pairingCode;

  // ---- State streams ----
  final _stateCtl = StreamController<HostState>.broadcast();
  final _displaysCtl = StreamController<List<DisplayInfo>>.broadcast();
  final _allParticipantsLeft = StreamController<void>.broadcast();

  Stream<HostState> get stateStream => _stateCtl.stream;
  Stream<List<DisplayInfo>> get displaysStream => _displaysCtl.stream;
  Stream<void> get onAllParticipantsLeft => _allParticipantsLeft.stream;

  // ---- Current-value accessors ----
  HostState _state = HostState.idle;
  List<DisplayInfo> _displays = const [];
  DisplayInfo? _activeDisplay;
  String? _lastError;

  HostState get state => _state;
  List<DisplayInfo> get displays => _displays;
  DisplayInfo? get activeDisplay => _activeDisplay;
  String? get lastError => _lastError;

  // ---- Injector helpers ----

  /// Whether the OS input-injection service/permission is available.
  Future<bool> isInjectorReady() => _injector.isReady();

  /// Trigger the platform-specific permission dialog / settings deep-link.
  Future<void> requestInjectorPermissions() => _injector.requestPermissions();

  // ---- Lifecycle ----

  /// Start screen sharing and connect to the LiveKit room.
  ///
  /// [liveKitUrl] — wss:// URL for the LiveKit server.
  /// [token]      — JWT obtained from your token endpoint.
  /// [sourceId]   — Desktop only (Windows/macOS/Linux): the
  ///                `DesktopCapturerSource.id` of the monitor to share.
  ///                Pass `null` to auto-select the primary monitor.
  ///                Ignored on Android/iOS.
  Future<void> start({
    required String liveKitUrl,
    required String token,
    String? sourceId,
  }) async {
    onLog?.call(
      '[HostSession] start() called: state=$_state url=$liveKitUrl '
      'tokenLen=${token.length} sourceId=$sourceId',
    );
    if (_state == HostState.starting || _state == HostState.connected) {
      onLog?.call('[HostSession] start() ignored: already $_state');
      return;
    }
    _setState(HostState.starting);
    try {
      // (No microphone permission needed — the host never publishes audio,
      // only the screen share video track.)
      if (Platform.isMacOS) {
        await _ensureMacScreenRecordingPermission();
      }

      onLog?.call('[HostSession] connecting to room...');
      await _roomSession.connect(url: liveKitUrl, token: token);
      onLog?.call('[HostSession] room connected');

      _listener = _roomSession.room.createListener();
      _listener!.on<DataReceivedEvent>(_onData);

      // Re-broadcast ScreenInfo to late-joining controllers AND start
      // capture on demand (first non-host participant joins).
      _listener!.on<ParticipantConnectedEvent>((_) async {
        try {
          await _ensureCapturing();
          final info = await _injector.screenInfo();
          await _roomSession.sendData(info.encode(), reliable: true);
          await _broadcastDisplays();
        } catch (_) {}
      });

      // Stop capture when the last non-host participant leaves so the
      // agent isn't burning CPU/GPU encoding for no one.
      _listener!.on<ParticipantDisconnectedEvent>((_) async {
        if (_roomSession.room.remoteParticipants.isEmpty) {
          try {
            await _stopCapturing();
          } catch (_) {}
          if (!_allParticipantsLeft.isClosed) _allParticipantsLeft.add(null);
        }
      });

      // Enumerate displays and resolve the capture source.
      ScreenShareCaptureOptions? screenOpts;
      rtc.DesktopCapturerSource? pickedSource;

      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        _displays = ScreenEnumerator.list();
        _displaysCtl.add(_displays);

        if (sourceId != null) {
          // Caller already picked a source — resolve it by id.
          final sources = await rtc.desktopCapturer.getSources(
            types: [rtc.SourceType.Screen],
          );
          _lastSources = sources;
          pickedSource = sources.firstWhere(
            (s) => s.id == sourceId,
            orElse: () => sources.first,
          );
        } else {
          // Auto-pick primary monitor.
          final sources = await rtc.desktopCapturer.getSources(
            types: [rtc.SourceType.Screen],
          );
          if (sources.isEmpty) {
            throw Exception('No screens available to share.');
          }
          _lastSources = sources;
          final primaryIdx = _displays.indexWhere((d) => d.isPrimary);
          final idx = (primaryIdx >= 0 && primaryIdx < sources.length)
              ? primaryIdx
              : 0;
          pickedSource = sources[idx];
        }

        screenOpts = ScreenShareCaptureOptions(
          sourceId: pickedSource.id,
          maxFrameRate: 60,
          params: _screenShareParams,
        );
      }

      // Resolve the picked source to a DisplayInfo.
      _activeDisplay = pickedSource == null
          ? null
          : await _resolveDisplay(pickedSource);
      _injector.setTargetDisplay(_activeDisplay);

      // Android: request notification permission and MediaProjection consent.
      if (Platform.isAndroid) {
        await Permission.notification.request();
        final granted = await rtc.Helper.requestCapturePermission();
        if (!granted) {
          throw Exception('Screen capture permission denied.');
        }
        try {
          await _androidChannel.invokeMethod('startScreenCaptureService');
        } catch (e) {
          throw Exception('Failed to start screen capture service: $e');
        }
      }

      // Cache capture options for lazy publishing; do NOT enable the
      // screen share track yet. We wait until a controller joins.
      _screenOpts = screenOpts;
      _activeSourceId = pickedSource?.id;

      // If a controller is already in the room (e.g. fast-joining client
      // beat us here), start capturing immediately.
      if (_roomSession.room.remoteParticipants.isNotEmpty) {
        await _ensureCapturing();
        final info = await _injector.screenInfo();
        await _roomSession.sendData(info.encode(), reliable: true);
        await _broadcastDisplays();
      }

      // Start IME focus → controller keyboard automation.
      await _focusSub?.cancel();
      _lastFocusBroadcast = false;
      _focusSub = _focusWatcher.editableFocused.listen((v) {
        if (v == _lastFocusBroadcast) return;
        _lastFocusBroadcast = v;
        _roomSession
            .sendData(ImeStateEvent(open: v).encode(), reliable: true)
            .catchError((_) {});
      });

      _setState(HostState.connected);
      onLog?.call('[HostSession] start() complete: connected');
    } catch (e, st) {
      onLog?.call('[HostSession] start() failed: $e\n$st');
      if (Platform.isAndroid) {
        try {
          await _androidChannel.invokeMethod('stopScreenCaptureService');
        } catch (_) {}
      }
      _lastError = e.toString();
      _setState(HostState.error);
    }
  }

  /// Enable the screen-share track on demand. Idempotent.
  Future<void> _ensureCapturing() async {
    if (_capturing) return;
    final lp = _roomSession.room.localParticipant;
    if (lp == null) return;
    await lp.setScreenShareEnabled(
      true,
      screenShareCaptureOptions: _screenOpts,
    );
    _capturing = true;
  }

  /// Disable the screen-share track but keep the room connection alive.
  /// Idempotent.
  Future<void> _stopCapturing() async {
    if (!_capturing) return;
    final lp = _roomSession.room.localParticipant;
    if (lp != null) {
      await lp.setScreenShareEnabled(false);
    }
    _capturing = false;
  }

  /// Send the current display list + active source id to all controllers
  /// over the reliable data channel. Best-effort; failures are swallowed
  /// (the next ParticipantConnectedEvent / switch will retry).
  Future<void> _broadcastDisplays() async {
    if (_lastSources.isEmpty || _displays.isEmpty) return;
    final n = min(_lastSources.length, _displays.length);
    final descriptors = <DisplayDescriptor>[
      for (var i = 0; i < n; i++)
        DisplayDescriptor(
          sourceId: _lastSources[i].id,
          label: _displays[i].label,
          isPrimary: _displays[i].isPrimary,
          width: _displays[i].width,
          height: _displays[i].height,
        ),
    ];
    final ev = DisplaysInfoEvent(
      displays: descriptors,
      activeSourceId: _activeSourceId,
    );
    try {
      await _roomSession.sendData(ev.encode(), reliable: true);
    } catch (_) {}
  }

  /// Stop sharing and disconnect from the room.
  Future<void> stop() async {
    await _focusSub?.cancel();
    _focusSub = null;
    await _listener?.dispose();
    _listener = null;
    if (Platform.isAndroid) {
      try {
        await _androidChannel.invokeMethod('stopScreenCaptureService');
      } catch (_) {}
    }
    _capturing = false;
    _screenOpts = null;
    _activeSourceId = null;
    _lastSources = const [];
    _injector.setTargetDisplay(null);
    _activeDisplay = null;
    await _roomSession.reset();
    _setState(HostState.idle);
  }

  /// Switch to a different desktop monitor (desktop only).
  ///
  /// [newSourceId] is the `DesktopCapturerSource.id` of the new monitor.
  Future<void> switchSource(String newSourceId) async {
    if (_state != HostState.connected) return;
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;

    final sources = await rtc.desktopCapturer.getSources(
      types: [rtc.SourceType.Screen],
    );
    final source = sources.firstWhere(
      (s) => s.id == newSourceId,
      orElse: () => throw ArgumentError('Source $newSourceId not found'),
    );

    final lp = _roomSession.room.localParticipant;
    if (lp == null) throw StateError('Not connected.');

    await lp.setScreenShareEnabled(false);
    await lp.setScreenShareEnabled(
      true,
      screenShareCaptureOptions: ScreenShareCaptureOptions(
        sourceId: source.id,
        maxFrameRate: 60,
        params: _screenShareParams,
      ),
    );

    _displays = ScreenEnumerator.list();
    _displaysCtl.add(_displays);
    _activeDisplay = await _resolveDisplay(source);
    _injector.setTargetDisplay(_activeDisplay);

    _activeSourceId = source.id;
    _lastSources = sources;

    final info = await _injector.screenInfo();
    await _roomSession.sendData(info.encode(), reliable: true);
    await _broadcastDisplays();
  }

  /// Dispose all resources. Safe to call multiple times.
  Future<void> dispose() async {
    if (_state == HostState.starting || _state == HostState.connected) {
      await stop();
    }
    _focusWatcher.dispose();
    if (!_stateCtl.isClosed) await _stateCtl.close();
    if (!_displaysCtl.isClosed) await _displaysCtl.close();
    if (!_allParticipantsLeft.isClosed) await _allParticipantsLeft.close();
  }

  // ---- Private ----

  void _onData(DataReceivedEvent ev) {
    final event = InputEvent.decode(ev.data);
    if (event == null) return;
    if (event is SwitchDisplayEvent) {
      switchSource(event.sourceId).catchError((_) {});
      return;
    }
    if (event is! MouseMoveEvent) {
      onLog?.call('[HostSession] received ${event.runtimeType}');
    }
    _injector.handle(event);
  }

  void _setState(HostState s) {
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  Future<DisplayInfo?> _resolveDisplay(rtc.DesktopCapturerSource picked) async {
    if (_displays.isEmpty) return null;
    try {
      final sources = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Screen],
      );
      final idx = sources.indexWhere((s) => s.id == picked.id);
      if (idx >= 0) return ScreenEnumerator.matchByIndex(idx, _displays);
    } catch (_) {}
    return ScreenEnumerator.match(
      picked.id,
      _displays,
      sourceName: picked.name,
    );
  }

  Future<void> _ensureMacScreenRecordingPermission() async {
    final cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    final preflight = cg.lookupFunction<Bool Function(), bool Function()>(
      'CGPreflightScreenCaptureAccess',
    );
    if (preflight()) return;
    final request = cg.lookupFunction<Bool Function(), bool Function()>(
      'CGRequestScreenCaptureAccess',
    );
    if (request()) return;
    throw Exception(
      'Screen Recording permission is required. '
      'Grant it in System Settings > Privacy & Security > Screen Recording, '
      'then restart the app.',
    );
  }

  static String _generateCode() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }
}
