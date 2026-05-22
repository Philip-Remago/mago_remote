import '../../protocol/input_event.dart';
import '../display_info.dart';
import 'input_injector.dart';

/// No-op injector used on platforms without injection support (Linux, Web, etc.)
class NoopInjector implements InputInjector {
  @override
  Future<bool> isReady() async => false;

  @override
  Future<void> requestPermissions() async {}

  @override
  void setTargetDisplay(DisplayInfo? display) {}

  @override
  Future<ScreenInfoEvent> screenInfo() async =>
      ScreenInfoEvent(width: 1920, height: 1080, scale: 1.0);

  @override
  Future<void> handle(InputEvent event) async {}
}
