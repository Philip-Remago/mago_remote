/// mago_remote — Flutter plugin for LiveKit-based remote desktop.
///
/// ## Exported surfaces
///
/// ### Controller side (the device driving the remote screen)
/// - [ControllerSession] — LiveKit connection + input event stream.
/// - [RemoteVideoView] — drop-in video widget with built-in gesture/keyboard handling.
/// - [RemoteVideoViewController] — optional handle to show/hide the on-screen keyboard.
///
/// ### Host side (the device sharing its screen)
/// - [HostSession] — screen sharing + input injection lifecycle.
/// - [DisplayInfo] — describes a physical monitor (desktop platforms).
///
/// ### Shared utilities
/// - [TokenClient] / [TokenException] — fetches LiveKit JWTs from your back-end.
library mago_remote;

export 'src/controller/controller_session.dart';
export 'src/controller/remote_video_view.dart';
export 'src/host/display_info.dart';
export 'src/host/host_session.dart';
export 'src/livekit/token_client.dart';
// Re-export the wire types the controller-facing API actually surfaces
// (so consumers can name them without importing the internal protocol).
export 'src/protocol/input_event.dart'
    show DisplayDescriptor, DisplaysInfoEvent;
