import 'package:flutter/services.dart';

import '../protocol/input_event.dart' as proto;

/// Bridges the OS soft keyboard (IME) to remote keystrokes WITHOUT using a
/// hidden TextField + FocusNode. We attach directly to [TextInput] with a
/// custom [TextInputClient] and diff editing-state changes into discrete
/// TextEvent / KeyInputEvent (Backspace / Enter) packets.
///
/// A zero-width sentinel character is kept in the buffer so the IME always
/// has "something to delete" — without it, pressing Backspace on an empty
/// editing state is a no-op on most IMEs and we'd never see a key event.
class ImeBridge with TextInputClient {
  ImeBridge({required this.send});

  /// Sends an event over the data channel to the host.
  final void Function(proto.InputEvent event, {bool reliable}) send;

  static const String _sentinel = '\u200b'; // zero-width space
  static const int _backspaceLogical = 0x100000008;
  static const int _backspacePhysical = 0x07002A;
  static const int _enterLogical = 0x100000005;
  static const int _enterPhysical = 0x070028;

  TextInputConnection? _conn;
  TextEditingValue _last = const TextEditingValue(
    text: _sentinel,
    selection: TextSelection.collapsed(offset: 1),
  );

  bool get isAttached => _conn?.attached ?? false;

  /// Show the OS soft keyboard and start streaming key/text events.
  void attach() {
    if (isAttached) {
      _conn!.show();
      return;
    }
    _conn = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        keyboardAppearance: Brightness.dark,
        // Android: tell the IME we don't want it to "learn" what the user
        // is typing — these are remote keystrokes, not local content.
        enableIMEPersonalizedLearning: false,
      ),
    );
    _last = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: 1),
    );
    _conn!.setEditingState(_last);
    _conn!.show();
  }

  /// Hide and detach. Safe to call when not attached.
  void detach() {
    _conn?.close();
    _conn = null;
  }

  // --------- TextInputClient ---------

  @override
  TextEditingValue? get currentTextEditingValue => _last;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    final oldText = _last.text;
    final newText = value.text;
    if (newText == oldText) {
      // Just selection movement; ignore.
      _last = value;
      return;
    }

    // 1) Detect a pure deletion (length shrank).
    if (newText.length < oldText.length) {
      final deletes = oldText.length - newText.length;
      for (var i = 0; i < deletes; i++) {
        send(
          proto.KeyInputEvent(
            logicalKey: _backspaceLogical,
            physicalKey: _backspacePhysical,
            down: true,
            modifiers: 0,
          ),
          reliable: true,
        );
        send(
          proto.KeyInputEvent(
            logicalKey: _backspaceLogical,
            physicalKey: _backspacePhysical,
            down: false,
            modifiers: 0,
          ),
          reliable: true,
        );
      }
    } else {
      // 2) Detect appended characters. Find the longest common prefix that
      //    starts with the sentinel; everything after is new input.
      var commonLen = 0;
      final maxLen = oldText.length < newText.length
          ? oldText.length
          : newText.length;
      while (commonLen < maxLen && oldText[commonLen] == newText[commonLen]) {
        commonLen++;
      }
      final added = newText.substring(commonLen);
      // If the IME replaced the buffer (e.g. swapped sentinel out), treat
      // the whole new text minus sentinel as added.
      final cleaned = added.replaceAll(_sentinel, '');
      if (cleaned.isNotEmpty) {
        send(proto.TextEvent(text: cleaned), reliable: true);
      }
    }

    // 3) Reset the buffer to the sentinel so the next edit always shows up
    //    as a diff against a known, single-character baseline.
    _last = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: 1),
    );
    _conn?.setEditingState(_last);
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.newline:
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.send:
      case TextInputAction.next:
      case TextInputAction.search:
        send(
          proto.KeyInputEvent(
            logicalKey: _enterLogical,
            physicalKey: _enterPhysical,
            down: true,
            modifiers: 0,
          ),
          reliable: true,
        );
        send(
          proto.KeyInputEvent(
            logicalKey: _enterLogical,
            physicalKey: _enterPhysical,
            down: false,
            modifiers: 0,
          ),
          reliable: true,
        );
        break;
      default:
        break;
    }
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void connectionClosed() {
    _conn = null;
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void performSelector(String selectorName) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}
}
