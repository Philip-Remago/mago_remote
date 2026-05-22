/// Description of one physical display attached to the host.
///
/// Used by the Host side only — not part of the controller wire protocol.
/// Coordinates and dimensions are in the OS' own global coordinate space:
///   • Windows  → virtual-desktop pixels (origin top-left of primary; the
///                secondary monitor can have negative x/y).
///   • macOS    → CG global points (Quartz coords; secondary can be negative).
class DisplayInfo {
  const DisplayInfo({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scale,
    required this.label,
    required this.isPrimary,
  });

  /// Best-effort key used to match against
  /// `DesktopCapturerSource.id` / `.name` returned by flutter_webrtc.
  ///   • Windows: device name like `\\.\DISPLAY1`.
  ///   • macOS:   stringified `CGDirectDisplayID`.
  final String id;

  final int x;
  final int y;
  final int width;
  final int height;

  /// Display scale factor (1.0 == 96 DPI on Windows, 1.0 == 1× on macOS).
  final double scale;

  /// Human-readable label shown in the Host UI ("Display 2 · 3840×2160").
  final String label;

  final bool isPrimary;
}
