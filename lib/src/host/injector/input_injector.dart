import 'dart:io' show Platform;

import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'android_injector.dart';
import 'mac_injector.dart';
import 'noop_injector.dart';
import 'windows_injector.dart';

/// OS-agnostic interface implemented per platform on the Host side.
///
/// All coordinate-bearing events use normalized [0.0, 1.0] values; each
/// implementation maps them to its own pixel/screen space.
abstract class InputInjector {
  /// Whether the OS has granted whatever permissions are required
  /// (Accessibility on macOS/Android, etc.). The Host UI uses this
  /// to surface a setup prompt.
  Future<bool> isReady();

  /// Trigger a platform-specific permission prompt or settings deep-link.
  Future<void> requestPermissions();

  /// Restrict subsequent injections to the given monitor. Pass `null` to
  /// fall back to the platform default (primary monitor / virtual desktop).
  /// Has no effect on platforms where multi-display targeting isn't a
  /// concept for injection (Android, iOS, Linux/no-op).
  void setTargetDisplay(DisplayInfo? display);

  /// The host's own logical screen size in physical pixels and DPI scale.
  /// Sent to the Controller so it can translate clicks accurately.
  Future<ScreenInfoEvent> screenInfo();

  Future<void> handle(InputEvent event);

  static InputInjector forCurrentPlatform() {
    if (Platform.isWindows) return WindowsInjector();
    if (Platform.isMacOS) return MacInjector();
    if (Platform.isAndroid) return AndroidInjector();
    return NoopInjector();
  }
}
