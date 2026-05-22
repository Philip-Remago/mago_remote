import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as w32;

import 'display_info.dart';

/// Enumerates the host's physical displays.
///
/// Used to (a) constrain input injection to the captured monitor, and
/// (b) populate the "Switch screen" picker on the Host UI.
class ScreenEnumerator {
  /// Returns the list of displays in OS enumeration order.
  static List<DisplayInfo> list() {
    if (Platform.isWindows) return _enumerateWindows();
    if (Platform.isMacOS) return _enumerateMac();
    return const [];
  }

  /// Best-effort match of a flutter_webrtc `DesktopCapturerSource.id` (and
  /// optional `name`) to a display in [displays]. Returns null if no
  /// confident match — caller should treat as "primary / unknown".
  ///
  /// On Windows, libwebrtc returns an opaque numeric id (e.g. a stringified
  /// monitor handle) that does NOT match the OS device path `\\.\DISPLAYn`.
  /// Prefer [matchByIndex] instead — call `desktopCapturer.getSources` with
  /// just `SourceType.Screen`, find the picked source's index, and pass that
  /// here. Both libwebrtc's screen capturer and `EnumDisplayMonitors` walk
  /// the OS in the same order, so index alignment is reliable.
  static DisplayInfo? matchByIndex(int index, List<DisplayInfo> displays) {
    if (displays.isEmpty) return null;
    if (index < 0 || index >= displays.length) {
      return displays.firstWhere(
        (d) => d.isPrimary,
        orElse: () => displays.first,
      );
    }
    return displays[index];
  }

  /// Legacy id/name heuristic. Kept as a last-ditch fallback when the
  /// caller can't supply an index.
  static DisplayInfo? match(
    String sourceId,
    List<DisplayInfo> displays, {
    String? sourceName,
  }) {
    if (displays.isEmpty) return null;
    for (final d in displays) {
      if (d.id == sourceId) return d;
    }
    for (final d in displays) {
      if (sourceId.contains(d.id) || d.id.contains(sourceId)) return d;
    }
    if (sourceName != null) {
      // flutter_webrtc tends to label screen sources "Screen 1", "Screen 2".
      final m = RegExp(r'(\d+)').firstMatch(sourceName);
      if (m != null) {
        final idx = int.parse(m.group(1)!) - 1;
        if (idx >= 0 && idx < displays.length) return displays[idx];
      }
    }
    final n = int.tryParse(sourceId.replaceAll(RegExp(r'\D'), ''));
    if (n != null && n >= 0 && n < displays.length) return displays[n];
    return displays.firstWhere(
      (d) => d.isPrimary,
      orElse: () => displays.first,
    );
  }

  // ---------------------------------------------------------------- Windows

  // Used as a sink by the EnumDisplayMonitors callback. Not reentrant — the
  // enum call is synchronous and single-shot, so this is fine.
  static List<DisplayInfo>? _winSink;

  static List<DisplayInfo> _enumerateWindows() {
    final out = <DisplayInfo>[];
    _winSink = out;
    final cb = NativeCallable<w32.MONITORENUMPROC>.isolateLocal(
      _winEnumProc,
      exceptionalReturn: 1,
    );
    try {
      w32.EnumDisplayMonitors(0, nullptr, cb.nativeFunction, 0);
    } finally {
      cb.close();
      _winSink = null;
    }
    return out;
  }

  static int _winEnumProc(int hMonitor, int hdc, Pointer lprect, int lparam) {
    final sink = _winSink;
    if (sink == null) return 1;
    final mi = calloc<w32.MONITORINFOEX>();
    try {
      mi.ref.monitorInfo.cbSize = sizeOf<w32.MONITORINFOEX>();
      if (w32.GetMonitorInfo(hMonitor, mi.cast()) != 0) {
        final r = mi.ref.monitorInfo.rcMonitor;
        // MONITORINFOF_PRIMARY = 0x1
        final isPrimary = (mi.ref.monitorInfo.dwFlags & 0x1) != 0;
        // MDT_EFFECTIVE_DPI = 0
        double scale = 1.0;
        final px = calloc<Uint32>();
        final py = calloc<Uint32>();
        try {
          final hr = w32.GetDpiForMonitor(hMonitor, 0, px, py);
          if (hr == 0 && px.value > 0) {
            scale = px.value / 96.0;
          }
        } finally {
          calloc.free(px);
          calloc.free(py);
        }
        final device = mi.ref.szDevice;
        final w = r.right - r.left;
        final h = r.bottom - r.top;
        sink.add(
          DisplayInfo(
            id: device,
            x: r.left,
            y: r.top,
            width: w,
            height: h,
            scale: scale,
            label:
                '${isPrimary ? "Primary" : "Display ${sink.length + 1}"} · '
                '$w×$h',
            isPrimary: isPrimary,
          ),
        );
      }
    } finally {
      calloc.free(mi);
    }
    return 1; // TRUE — continue enumeration
  }

  // ------------------------------------------------------------------ macOS

  static List<DisplayInfo> _enumerateMac() {
    final cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    final cgGetActiveDisplayList = cg
        .lookupFunction<
          Int32 Function(Uint32, Pointer<Uint32>, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>, Pointer<Uint32>)
        >('CGGetActiveDisplayList');
    final cgMainDisplayId = cg
        .lookupFunction<Uint32 Function(), int Function()>('CGMainDisplayID');
    final cgDisplayPixelsWide = cg
        .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
          'CGDisplayPixelsWide',
        );
    final cgDisplayPixelsHigh = cg
        .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
          'CGDisplayPixelsHigh',
        );
    final cgDisplayBounds = cg
        .lookupFunction<_CGRect Function(Uint32), _CGRect Function(int)>(
          'CGDisplayBounds',
        );

    final out = <DisplayInfo>[];
    const maxN = 16;
    final ids = calloc<Uint32>(maxN);
    final count = calloc<Uint32>();
    try {
      if (cgGetActiveDisplayList(maxN, ids, count) != 0) return const [];
      final n = count.value;
      final main = cgMainDisplayId();
      for (var i = 0; i < n; i++) {
        final id = ids[i];
        final b = cgDisplayBounds(id);
        final pxW = cgDisplayPixelsWide(id);
        final pxH = cgDisplayPixelsHigh(id);
        final ptW = b.size.width.round();
        final ptH = b.size.height.round();
        final scale = ptW > 0 ? pxW / ptW : 1.0;
        final isPrimary = id == main;
        out.add(
          DisplayInfo(
            id: id.toString(),
            // Bounds are in *points*; injector posts in points too, so we
            // store them as ints and trust the rounding.
            x: b.origin.x.round(),
            y: b.origin.y.round(),
            width: ptW,
            height: ptH,
            scale: scale.toDouble(),
            label:
                '${isPrimary ? "Primary" : "Display ${i + 1}"} · '
                '$pxW×$pxH',
            isPrimary: isPrimary,
          ),
        );
      }
    } finally {
      calloc.free(ids);
      calloc.free(count);
    }
    return out;
  }
}

// CGRect / CGPoint / CGSize for FFI return-by-value.
final class _CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class _CGSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}

final class _CGRect extends Struct {
  external _CGPoint origin;
  external _CGSize size;
}
