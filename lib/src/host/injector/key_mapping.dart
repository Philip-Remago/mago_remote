/// HID Usage ID → platform native scancode/keycode lookup tables.
///
/// Controller events carry [KeyInputEvent.physicalKey] as a Flutter
/// [PhysicalKeyboardKey.usbHidUsage] value, which is the USB HID Keyboard
/// /Keypad page (0x07) usage ID OR'd with the page in the high bits
/// (e.g. Enter = 0x070028). The injectors convert that back to whatever
/// the OS expects:
///
///   * Windows: Virtual-Key code (VK_*) + an "extended" flag for keys
///     that need the 0xE0 scan prefix (arrows, navigation, right-side
///     modifiers, numpad enter/divide). We prefer VK over raw scancode
///     because Windows applies the active keyboard layout to letters
///     automatically — so Ctrl+C still triggers the 'copy' shortcut on
///     a German layout where physical 'Z' lives where 'Y' would on US.
///
///   * macOS: kVK_* virtual keycode. Layout-independent for control
///     keys; for letters we still go through CGEventCreateKeyboardEvent
///     which respects the current input source.
///
/// Tables are deliberately verbose (no clever bit-fiddling) to make it
/// easy to spot mistakes.
library;

/// (Windows VK, isExtended) for a USB HID Usage ID, or null if unmapped.
({int vk, bool extended})? windowsKeyFromHid(int hid) {
  final usage = hid & 0xFFFF; // page 0x07 in high bits, usage in low bits
  return _hidToWin[usage];
}

/// macOS kVK_* virtual keycode for a USB HID Usage ID, or null if unmapped.
int? macKeyCodeFromHid(int hid) {
  final usage = hid & 0xFFFF;
  return _hidToMac[usage];
}

// =====================================================================
// Windows: HID Usage ID -> (VK_*, extended-key flag)
// =====================================================================
//
// VK constants from <winuser.h>. The extended flag matters for
// SendInput's KEYEVENTF_EXTENDEDKEY: the keys that share a scancode
// with their numpad twin (arrows vs numpad arrows, Enter vs numpad
// Enter, etc.) and the right-side modifiers all need it set so the
// OS can disambiguate.
const Map<int, ({int vk, bool extended})> _hidToWin = {
  // --- Letters: VK_A..VK_Z = 0x41..0x5A ---
  0x04: (vk: 0x41, extended: false), // A
  0x05: (vk: 0x42, extended: false), // B
  0x06: (vk: 0x43, extended: false), // C
  0x07: (vk: 0x44, extended: false), // D
  0x08: (vk: 0x45, extended: false), // E
  0x09: (vk: 0x46, extended: false), // F
  0x0A: (vk: 0x47, extended: false), // G
  0x0B: (vk: 0x48, extended: false), // H
  0x0C: (vk: 0x49, extended: false), // I
  0x0D: (vk: 0x4A, extended: false), // J
  0x0E: (vk: 0x4B, extended: false), // K
  0x0F: (vk: 0x4C, extended: false), // L
  0x10: (vk: 0x4D, extended: false), // M
  0x11: (vk: 0x4E, extended: false), // N
  0x12: (vk: 0x4F, extended: false), // O
  0x13: (vk: 0x50, extended: false), // P
  0x14: (vk: 0x51, extended: false), // Q
  0x15: (vk: 0x52, extended: false), // R
  0x16: (vk: 0x53, extended: false), // S
  0x17: (vk: 0x54, extended: false), // T
  0x18: (vk: 0x55, extended: false), // U
  0x19: (vk: 0x56, extended: false), // V
  0x1A: (vk: 0x57, extended: false), // W
  0x1B: (vk: 0x58, extended: false), // X
  0x1C: (vk: 0x59, extended: false), // Y
  0x1D: (vk: 0x5A, extended: false), // Z
  // --- Top-row digits: VK_0..VK_9 = 0x30..0x39 ---
  0x1E: (vk: 0x31, extended: false), // 1
  0x1F: (vk: 0x32, extended: false), // 2
  0x20: (vk: 0x33, extended: false), // 3
  0x21: (vk: 0x34, extended: false), // 4
  0x22: (vk: 0x35, extended: false), // 5
  0x23: (vk: 0x36, extended: false), // 6
  0x24: (vk: 0x37, extended: false), // 7
  0x25: (vk: 0x38, extended: false), // 8
  0x26: (vk: 0x39, extended: false), // 9
  0x27: (vk: 0x30, extended: false), // 0
  // --- Control keys ---
  0x28: (vk: 0x0D, extended: false), // Enter -> VK_RETURN
  0x29: (vk: 0x1B, extended: false), // Escape -> VK_ESCAPE
  0x2A: (vk: 0x08, extended: false), // Backspace -> VK_BACK
  0x2B: (vk: 0x09, extended: false), // Tab -> VK_TAB
  0x2C: (vk: 0x20, extended: false), // Space -> VK_SPACE
  0x2D: (vk: 0xBD, extended: false), // - / VK_OEM_MINUS
  0x2E: (vk: 0xBB, extended: false), // = / VK_OEM_PLUS
  0x2F: (vk: 0xDB, extended: false), // [ / VK_OEM_4
  0x30: (vk: 0xDD, extended: false), // ] / VK_OEM_6
  0x31: (vk: 0xDC, extended: false), // \ / VK_OEM_5
  0x32: (vk: 0xDF, extended: false), // non-US # / VK_OEM_8
  0x33: (vk: 0xBA, extended: false), // ; / VK_OEM_1
  0x34: (vk: 0xDE, extended: false), // ' / VK_OEM_7
  0x35: (vk: 0xC0, extended: false), // ` / VK_OEM_3
  0x36: (vk: 0xBC, extended: false), // , / VK_OEM_COMMA
  0x37: (vk: 0xBE, extended: false), // . / VK_OEM_PERIOD
  0x38: (vk: 0xBF, extended: false), // / / VK_OEM_2
  0x39: (vk: 0x14, extended: false), // CapsLock -> VK_CAPITAL
  // --- Function keys: VK_F1..VK_F24 = 0x70..0x87 ---
  0x3A: (vk: 0x70, extended: false), // F1
  0x3B: (vk: 0x71, extended: false), // F2
  0x3C: (vk: 0x72, extended: false), // F3
  0x3D: (vk: 0x73, extended: false), // F4
  0x3E: (vk: 0x74, extended: false), // F5
  0x3F: (vk: 0x75, extended: false), // F6
  0x40: (vk: 0x76, extended: false), // F7
  0x41: (vk: 0x77, extended: false), // F8
  0x42: (vk: 0x78, extended: false), // F9
  0x43: (vk: 0x79, extended: false), // F10
  0x44: (vk: 0x7A, extended: false), // F11
  0x45: (vk: 0x7B, extended: false), // F12
  0x68: (vk: 0x7C, extended: false), // F13
  0x69: (vk: 0x7D, extended: false), // F14
  0x6A: (vk: 0x7E, extended: false), // F15
  0x6B: (vk: 0x7F, extended: false), // F16
  0x6C: (vk: 0x80, extended: false), // F17
  0x6D: (vk: 0x81, extended: false), // F18
  0x6E: (vk: 0x82, extended: false), // F19
  0x6F: (vk: 0x83, extended: false), // F20
  0x70: (vk: 0x84, extended: false), // F21
  0x71: (vk: 0x85, extended: false), // F22
  0x72: (vk: 0x86, extended: false), // F23
  0x73: (vk: 0x87, extended: false), // F24
  // --- Navigation cluster (extended) ---
  0x46: (vk: 0x2C, extended: true), // PrintScreen -> VK_SNAPSHOT
  0x47: (vk: 0x91, extended: false), // ScrollLock -> VK_SCROLL
  0x48: (vk: 0x13, extended: false), // Pause -> VK_PAUSE
  0x49: (vk: 0x2D, extended: true), // Insert -> VK_INSERT
  0x4A: (vk: 0x24, extended: true), // Home -> VK_HOME
  0x4B: (vk: 0x21, extended: true), // PageUp -> VK_PRIOR
  0x4C: (vk: 0x2E, extended: true), // Delete -> VK_DELETE
  0x4D: (vk: 0x23, extended: true), // End -> VK_END
  0x4E: (vk: 0x22, extended: true), // PageDown -> VK_NEXT
  0x4F: (vk: 0x27, extended: true), // Right -> VK_RIGHT
  0x50: (vk: 0x25, extended: true), // Left -> VK_LEFT
  0x51: (vk: 0x28, extended: true), // Down -> VK_DOWN
  0x52: (vk: 0x26, extended: true), // Up -> VK_UP
  // --- Numpad ---
  0x53: (vk: 0x90, extended: false), // NumLock -> VK_NUMLOCK
  0x54: (vk: 0x6F, extended: true), // Numpad / -> VK_DIVIDE (extended)
  0x55: (vk: 0x6A, extended: false), // Numpad * -> VK_MULTIPLY
  0x56: (vk: 0x6D, extended: false), // Numpad - -> VK_SUBTRACT
  0x57: (vk: 0x6B, extended: false), // Numpad + -> VK_ADD
  0x58: (vk: 0x0D, extended: true), // Numpad Enter -> VK_RETURN extended
  0x59: (vk: 0x61, extended: false), // Numpad 1 -> VK_NUMPAD1
  0x5A: (vk: 0x62, extended: false), // Numpad 2
  0x5B: (vk: 0x63, extended: false), // Numpad 3
  0x5C: (vk: 0x64, extended: false), // Numpad 4
  0x5D: (vk: 0x65, extended: false), // Numpad 5
  0x5E: (vk: 0x66, extended: false), // Numpad 6
  0x5F: (vk: 0x67, extended: false), // Numpad 7
  0x60: (vk: 0x68, extended: false), // Numpad 8
  0x61: (vk: 0x69, extended: false), // Numpad 9
  0x62: (vk: 0x60, extended: false), // Numpad 0
  0x63: (vk: 0x6E, extended: false), // Numpad . -> VK_DECIMAL
  0x65: (vk: 0x5D, extended: true), // Application/Menu -> VK_APPS
  // --- Modifiers ---
  0xE0: (vk: 0xA2, extended: false), // L Ctrl -> VK_LCONTROL
  0xE1: (vk: 0xA0, extended: false), // L Shift -> VK_LSHIFT
  0xE2: (vk: 0xA4, extended: false), // L Alt -> VK_LMENU
  0xE3: (vk: 0x5B, extended: true), // L Meta/Win -> VK_LWIN (extended)
  0xE4: (vk: 0xA3, extended: true), // R Ctrl -> VK_RCONTROL (extended)
  0xE5: (vk: 0xA1, extended: false), // R Shift -> VK_RSHIFT
  0xE6: (vk: 0xA5, extended: true), // R Alt / AltGr -> VK_RMENU (extended)
  0xE7: (vk: 0x5C, extended: true), // R Meta -> VK_RWIN (extended)
};

// =====================================================================
// macOS: HID Usage ID -> kVK_* virtual keycode.
// =====================================================================
//
// Constants from <Carbon/HIToolbox/Events.h>. Values for layout-
// dependent letters/digits map to the "ANSI" position; macOS itself
// applies the user's keyboard layout, so e.g. kVK_ANSI_C still means
// "the key labelled C on a US layout, whatever that physical key is on
// the user's actual layout" — same behaviour as Windows VK codes.
const Map<int, int> _hidToMac = {
  // Letters (kVK_ANSI_*)
  0x04: 0x00, // A
  0x05: 0x0B, // B
  0x06: 0x08, // C
  0x07: 0x02, // D
  0x08: 0x0E, // E
  0x09: 0x03, // F
  0x0A: 0x05, // G
  0x0B: 0x04, // H
  0x0C: 0x22, // I
  0x0D: 0x26, // J
  0x0E: 0x28, // K
  0x0F: 0x25, // L
  0x10: 0x2E, // M
  0x11: 0x2D, // N
  0x12: 0x1F, // O
  0x13: 0x23, // P
  0x14: 0x0C, // Q
  0x15: 0x0F, // R
  0x16: 0x01, // S
  0x17: 0x11, // T
  0x18: 0x20, // U
  0x19: 0x09, // V
  0x1A: 0x0D, // W
  0x1B: 0x07, // X
  0x1C: 0x10, // Y
  0x1D: 0x06, // Z
  // Digits
  0x1E: 0x12, // 1
  0x1F: 0x13, // 2
  0x20: 0x14, // 3
  0x21: 0x15, // 4
  0x22: 0x17, // 5
  0x23: 0x16, // 6
  0x24: 0x1A, // 7
  0x25: 0x1C, // 8
  0x26: 0x19, // 9
  0x27: 0x1D, // 0
  // Control keys
  0x28: 0x24, // Enter -> kVK_Return
  0x29: 0x35, // Escape
  0x2A: 0x33, // Backspace -> kVK_Delete
  0x2B: 0x30, // Tab
  0x2C: 0x31, // Space
  0x2D: 0x1B, // -
  0x2E: 0x18, // =
  0x2F: 0x21, // [
  0x30: 0x1E, // ]
  0x31: 0x2A, // backslash
  0x33: 0x29, // ;
  0x34: 0x27, // '
  0x35: 0x32, // `
  0x36: 0x2B, // ,
  0x37: 0x2F, // .
  0x38: 0x2C, // /
  0x39: 0x39, // CapsLock
  // Function keys
  0x3A: 0x7A, // F1
  0x3B: 0x78, // F2
  0x3C: 0x63, // F3
  0x3D: 0x76, // F4
  0x3E: 0x60, // F5
  0x3F: 0x61, // F6
  0x40: 0x62, // F7
  0x41: 0x64, // F8
  0x42: 0x65, // F9
  0x43: 0x6D, // F10
  0x44: 0x67, // F11
  0x45: 0x6F, // F12
  0x68: 0x69, // F13
  0x69: 0x6B, // F14
  0x6A: 0x71, // F15
  0x6B: 0x6A, // F16
  0x6C: 0x40, // F17
  0x6D: 0x4F, // F18
  0x6E: 0x50, // F19
  0x6F: 0x5A, // F20
  // Navigation
  0x49: 0x72, // Insert -> kVK_Help
  0x4A: 0x73, // Home
  0x4B: 0x74, // PageUp
  0x4C: 0x75, // ForwardDelete
  0x4D: 0x77, // End
  0x4E: 0x79, // PageDown
  0x4F: 0x7C, // Right
  0x50: 0x7B, // Left
  0x51: 0x7D, // Down
  0x52: 0x7E, // Up
  // Numpad
  0x53: 0x47, // Clear / NumLock -> kVK_ANSI_KeypadClear
  0x54: 0x4B, // /
  0x55: 0x43, // *
  0x56: 0x4E, // -
  0x57: 0x45, // +
  0x58: 0x4C, // Enter
  0x59: 0x53, // 1
  0x5A: 0x54, // 2
  0x5B: 0x55, // 3
  0x5C: 0x56, // 4
  0x5D: 0x57, // 5
  0x5E: 0x58, // 6
  0x5F: 0x59, // 7
  0x60: 0x5B, // 8
  0x61: 0x5C, // 9
  0x62: 0x52, // 0
  0x63: 0x41, // .
  // Modifiers
  0xE0: 0x3B, // L Ctrl
  0xE1: 0x38, // L Shift
  0xE2: 0x3A, // L Alt/Option
  0xE3: 0x37, // L Meta/Cmd
  0xE4: 0x3E, // R Ctrl
  0xE5: 0x3C, // R Shift
  0xE6: 0x3D, // R Alt
  0xE7: 0x36, // R Meta/Cmd
};
