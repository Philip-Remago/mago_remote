import 'dart:async';
import 'dart:ui' show Offset;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mago_remote/src/controller/gesture_translator.dart';
import 'package:mago_remote/src/protocol/input_event.dart' as proto;

/// Tests for [GestureTranslator] — the controller-side translator that
/// converts raw Flutter pointer events into wire-protocol input events.
void main() {
  late List<proto.InputEvent> sent;
  late GestureTranslator gt;

  setUp(() {
    sent = [];
    gt = GestureTranslator(send: (e, {bool reliable = true}) => sent.add(e));
  });

  // ---------------------------------------------------------------- helpers
  PointerDownEvent down({
    required int pointer,
    required Offset local,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    int buttons = kPrimaryMouseButton,
  }) => PointerDownEvent(
    pointer: pointer,
    position: local,
    kind: kind,
    buttons: buttons,
  );

  PointerMoveEvent move({
    required int pointer,
    required Offset local,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    int buttons = kPrimaryMouseButton,
  }) => PointerMoveEvent(
    pointer: pointer,
    position: local,
    kind: kind,
    buttons: buttons,
  );

  PointerUpEvent up({
    required int pointer,
    required Offset local,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) => PointerUpEvent(pointer: pointer, position: local, kind: kind);

  PointerScrollEvent wheel({
    required Offset local,
    required Offset scrollDelta,
  }) => PointerScrollEvent(
    position: local,
    scrollDelta: scrollDelta,
    kind: PointerDeviceKind.mouse,
  );

  // ============================================================ touch host
  group('Touch host (hostNativeTouch=true)', () {
    test('mouse drag -> single synthetic finger TouchDown/Move/Up', () {
      gt.onPointerDown(
        event: down(pointer: 1, local: const Offset(100, 100)),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: true,
        isControlPressed: false,
      );
      gt.onPointerMove(
        event: move(pointer: 1, local: const Offset(150, 100)),
        hostPoint: const Offset(0.6, 0.5),
        hostNativeTouch: true,
      );
      gt.onPointerUp(
        event: up(pointer: 1, local: const Offset(150, 100)),
        hostPoint: const Offset(0.6, 0.5),
        hostNativeTouch: true,
      );

      expect(sent, hasLength(3));
      final d = sent[0] as proto.TouchDownEvent;
      expect(d.id, -1);
      expect(d.x, 0.5);
      final m = sent[1] as proto.TouchMoveEvent;
      expect(m.id, -1);
      final u = sent[2] as proto.TouchUpEvent;
      expect(u.id, -1);
      expect(u.cancel, false);
    });

    test('mouse tap (down + up, no move) -> Down + Up at same point', () {
      gt.onPointerDown(
        event: down(pointer: 7, local: const Offset(50, 50)),
        hostPoint: const Offset(0.25, 0.25),
        hostNativeTouch: true,
        isControlPressed: false,
      );
      gt.onPointerUp(
        event: up(pointer: 7, local: const Offset(50, 50)),
        hostPoint: const Offset(0.25, 0.25),
        hostNativeTouch: true,
      );
      expect(sent, hasLength(2));
      expect(sent[0], isA<proto.TouchDownEvent>());
      expect(sent[1], isA<proto.TouchUpEvent>());
      expect((sent[1] as proto.TouchUpEvent).id, -1);
    });

    test('Ctrl+mouse drag -> two synthetic fingers', () {
      gt.onPointerDown(
        event: down(pointer: 2, local: const Offset(500, 500)),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: true,
        isControlPressed: true,
      );
      // Two TouchDowns at ±0.04 around cursor.x.
      expect(sent, hasLength(2));
      final a = sent[0] as proto.TouchDownEvent;
      final b = sent[1] as proto.TouchDownEvent;
      expect(a.id, -20);
      expect(b.id, -21);
      expect(a.x, closeTo(0.46, 1e-9));
      expect(b.x, closeTo(0.54, 1e-9));
      expect(a.y, 0.5);

      sent.clear();
      gt.onPointerMove(
        event: move(pointer: 2, local: const Offset(500, 400)),
        hostPoint: const Offset(0.5, 0.4),
        hostNativeTouch: true,
      );
      // Both fingers translated by (-0, -0.1) — same x as their initial.
      expect(sent, hasLength(2));
      final ma = sent[0] as proto.TouchMoveEvent;
      final mb = sent[1] as proto.TouchMoveEvent;
      expect(ma.id, -20);
      expect(mb.id, -21);
      expect(ma.y, closeTo(0.4, 1e-9));
      expect(mb.y, closeTo(0.4, 1e-9));

      sent.clear();
      gt.onPointerUp(
        event: up(pointer: 2, local: const Offset(500, 400)),
        hostPoint: const Offset(0.5, 0.4),
        hostNativeTouch: true,
      );
      expect(sent, hasLength(2));
      expect((sent[0] as proto.TouchUpEvent).id, -20);
      expect((sent[1] as proto.TouchUpEvent).id, -21);
    });

    test('right-click on touch host emits no events', () {
      gt.onPointerDown(
        event: down(
          pointer: 9,
          local: const Offset(10, 10),
          buttons: kSecondaryMouseButton,
        ),
        hostPoint: const Offset(0.1, 0.1),
        hostNativeTouch: true,
        isControlPressed: false,
      );
      gt.onPointerUp(
        event: up(pointer: 9, local: const Offset(10, 10)),
        hostPoint: const Offset(0.1, 0.1),
        hostNativeTouch: true,
      );
      expect(sent, isEmpty);
    });

    test('real finger forwards as TouchDown/Move/Up with real pointer id', () {
      gt.onPointerDown(
        event: down(
          pointer: 42,
          local: const Offset(100, 100),
          kind: PointerDeviceKind.touch,
          buttons: 0,
        ),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: true,
        isControlPressed: false,
      );
      gt.onPointerUp(
        event: up(
          pointer: 42,
          local: const Offset(100, 100),
          kind: PointerDeviceKind.touch,
        ),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: true,
      );
      expect(sent, hasLength(2));
      expect((sent[0] as proto.TouchDownEvent).id, 42);
      expect((sent[1] as proto.TouchUpEvent).id, 42);
    });
  });

  // ============================================================ wheel
  group('Wheel on touch host', () {
    test('single notch -> Down + Move; idle 150ms -> Up', () {
      fakeAsync((async) {
        final gtTimed = GestureTranslator(
          send: (e, {bool reliable = true}) => sent.add(e),
          timerFactory: (d, cb) => Timer(d, cb),
        );
        gtTimed.onPointerSignal(
          event: wheel(
            local: const Offset(100, 100),
            scrollDelta: const Offset(0, 50),
          ),
          hostPoint: const Offset(0.5, 0.5),
          hostNativeTouch: true,
          isControlPressed: false,
        );
        // Down + Move so far, no Up yet.
        expect(sent.whereType<proto.TouchDownEvent>(), hasLength(1));
        expect(sent.whereType<proto.TouchMoveEvent>(), hasLength(1));
        expect(sent.whereType<proto.TouchUpEvent>(), isEmpty);
        expect((sent[0] as proto.TouchDownEvent).id, -30);

        async.elapse(const Duration(milliseconds: 200));
        // Idle-lift fired.
        expect(sent.whereType<proto.TouchUpEvent>(), hasLength(1));
        expect((sent.last as proto.TouchUpEvent).id, -30);
      });
    });

    test('two notches in quick succession stitch into one stroke', () {
      fakeAsync((async) {
        final gtTimed = GestureTranslator(
          send: (e, {bool reliable = true}) => sent.add(e),
          timerFactory: (d, cb) => Timer(d, cb),
        );
        gtTimed.onPointerSignal(
          event: wheel(
            local: const Offset(0, 0),
            scrollDelta: const Offset(0, 50),
          ),
          hostPoint: const Offset(0.5, 0.5),
          hostNativeTouch: true,
          isControlPressed: false,
        );
        async.elapse(const Duration(milliseconds: 50));
        gtTimed.onPointerSignal(
          event: wheel(
            local: const Offset(0, 0),
            scrollDelta: const Offset(0, 50),
          ),
          hostPoint: const Offset(0.5, 0.5),
          hostNativeTouch: true,
          isControlPressed: false,
        );
        async.elapse(const Duration(milliseconds: 200));

        // 1 Down + 2 Move + 1 Up.
        expect(sent.whereType<proto.TouchDownEvent>(), hasLength(1));
        expect(sent.whereType<proto.TouchMoveEvent>(), hasLength(2));
        expect(sent.whereType<proto.TouchUpEvent>(), hasLength(1));
      });
    });

    test('Ctrl+wheel pinch -> two fingers spread on scroll up', () {
      fakeAsync((async) {
        final gtTimed = GestureTranslator(
          send: (e, {bool reliable = true}) => sent.add(e),
          timerFactory: (d, cb) => Timer(d, cb),
        );
        gtTimed.onPointerSignal(
          event: wheel(
            local: const Offset(0, 0),
            // negative scrollDelta.dy = scroll up = zoom in.
            scrollDelta: const Offset(0, -50),
          ),
          hostPoint: const Offset(0.5, 0.5),
          hostNativeTouch: true,
          isControlPressed: true,
        );
        // 2 Down + 2 Move (no Up yet).
        final downs = sent.whereType<proto.TouchDownEvent>().toList();
        final moves = sent.whereType<proto.TouchMoveEvent>().toList();
        expect(downs, hasLength(2));
        expect(moves, hasLength(2));
        expect(downs[0].id, -10);
        expect(downs[1].id, -11);
        // Initial offset ±0.06 around cursor; after one notch (+1) of
        // scroll-up, finger A moved further left and B further right.
        expect(moves[0].x, lessThan(downs[0].x));
        expect(moves[1].x, greaterThan(downs[1].x));

        async.elapse(const Duration(milliseconds: 200));
        expect(sent.whereType<proto.TouchUpEvent>(), hasLength(2));
      });
    });
  });

  // ============================================================ desktop host
  group('Desktop host (hostNativeTouch=false)', () {
    test('mouse left-down -> MouseButton(left, down)', () {
      gt.onPointerDown(
        event: down(pointer: 1, local: const Offset(0, 0)),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: false,
        isControlPressed: false,
      );
      expect(sent, hasLength(1));
      final e = sent.single as proto.MouseButtonEvent;
      expect(e.button, proto.MouseButton.left);
      expect(e.down, true);
    });

    test('mouse drag -> MouseButton(down) + MouseMove* + MouseButton(up)', () {
      gt.onPointerDown(
        event: down(pointer: 1, local: const Offset(0, 0)),
        hostPoint: const Offset(0.1, 0.1),
        hostNativeTouch: false,
        isControlPressed: false,
      );
      gt.onPointerMove(
        event: move(pointer: 1, local: const Offset(50, 0)),
        hostPoint: const Offset(0.2, 0.1),
        hostNativeTouch: false,
      );
      gt.onPointerUp(
        event: up(pointer: 1, local: const Offset(50, 0)),
        hostPoint: const Offset(0.2, 0.1),
        hostNativeTouch: false,
      );
      expect(sent, hasLength(3));
      expect(sent[0], isA<proto.MouseButtonEvent>());
      expect(sent[1], isA<proto.MouseMoveEvent>());
      expect(sent[2], isA<proto.MouseButtonEvent>());
      expect((sent[2] as proto.MouseButtonEvent).down, false);
    });

    test('wheel -> MouseWheelEvent', () {
      gt.onPointerSignal(
        event: wheel(
          local: const Offset(0, 0),
          scrollDelta: const Offset(0, 50),
        ),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: false,
        isControlPressed: false,
      );
      expect(sent, hasLength(1));
      final e = sent.single as proto.MouseWheelEvent;
      expect(e.dy, closeTo(-1.0, 1e-9));
    });

    test('touch on desktop host: long-press -> right-click', () {
      fakeAsync((async) {
        final gtTimed = GestureTranslator(
          send: (e, {bool reliable = true}) => sent.add(e),
          timerFactory: (d, cb) => Timer(d, cb),
        );
        gtTimed.onPointerDown(
          event: down(
            pointer: 1,
            local: const Offset(0, 0),
            kind: PointerDeviceKind.touch,
            buttons: 0,
          ),
          hostPoint: const Offset(0.5, 0.5),
          hostNativeTouch: false,
          isControlPressed: false,
        );
        // No events yet — waiting for long-press timer.
        expect(sent, isEmpty);
        async.elapse(const Duration(milliseconds: 600));
        expect(sent, hasLength(2));
        expect(
          (sent[0] as proto.MouseButtonEvent).button,
          proto.MouseButton.right,
        );
      });
    });

    test('touch on desktop host: quick tap -> left click pair', () {
      gt.onPointerDown(
        event: down(
          pointer: 1,
          local: const Offset(0, 0),
          kind: PointerDeviceKind.touch,
          buttons: 0,
        ),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: false,
        isControlPressed: false,
      );
      gt.onPointerUp(
        event: up(
          pointer: 1,
          local: const Offset(0, 0),
          kind: PointerDeviceKind.touch,
        ),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: false,
      );
      expect(sent, hasLength(2));
      final d = sent[0] as proto.MouseButtonEvent;
      final u = sent[1] as proto.MouseButtonEvent;
      expect(d.button, proto.MouseButton.left);
      expect(d.down, true);
      expect(u.down, false);
    });
  });

  // ============================================================ reset
  test('reset() clears in-flight pointers and timers', () {
    fakeAsync((async) {
      final gtTimed = GestureTranslator(
        send: (e, {bool reliable = true}) => sent.add(e),
        timerFactory: (d, cb) => Timer(d, cb),
      );
      gtTimed.onPointerSignal(
        event: wheel(
          local: const Offset(0, 0),
          scrollDelta: const Offset(0, 50),
        ),
        hostPoint: const Offset(0.5, 0.5),
        hostNativeTouch: true,
        isControlPressed: false,
      );
      gtTimed.reset();
      sent.clear();
      async.elapse(const Duration(seconds: 1));
      // Idle-lift timer was cancelled, no Up should arrive.
      expect(sent, isEmpty);
    });
  });
}
