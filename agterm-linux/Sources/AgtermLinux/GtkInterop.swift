// Low-level GTK4 C-interop helpers. GTK's GObject types import into Swift as
// distinct typed pointers; these reinterpret a stored OpaquePointer to the type
// a given GTK function expects (GObject pointers are layout-compatible).
import CGtk
import agtermCore

// GTK, GApplication, and GLib source callbacks are declared `@MainActor @convention(c)` at their
// definitions. The C APIs cannot express executor isolation, but these callbacks are synchronously
// delivered by the application-owned main context. Libghostty callbacks are intentionally excluded:
// they may arrive on worker threads and must copy/retain their payload before hopping to the main actor.

@inline(__always) func W(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkWidget>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GLBR(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkListBoxRow>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GLA(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkGLArea>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func WIN(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkWindow>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func APPW(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func ADWAPP(_ p: OpaquePointer?) -> UnsafeMutablePointer<AdwApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GAPP(_ p: OpaquePointer?) -> UnsafeMutablePointer<GApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GOBJ(_ p: OpaquePointer?) -> UnsafeMutablePointer<GObject>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func POPOVER(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkPopover>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func BUTTON(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkButton>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func RAW(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }

/// Normalize a GTK constructor result (which inconsistently imports as optional or
/// non-optional `UnsafeMutablePointer<GtkWidget>`) to the `OpaquePointer?` we store.
@inline(__always) func op(_ p: UnsafeMutablePointer<GtkWidget>?) -> OpaquePointer? { p.map { OpaquePointer($0) } }

/// Connect a GObject signal, passing `data` to the handler's trailing argument.
/// `handler` is a non-capturing `@convention(c)` function cast to `GCallback`.
func connect(_ instance: OpaquePointer?, _ signal: String, _ handler: GCallback?, _ data: UnsafeMutableRawPointer? = nil) {
    signal.withCString { _ = g_signal_connect_data(RAW(instance), $0, handler, data, nil, GConnectFlags(rawValue: 0)) }
}

// GDK modifier bit masks (GdkModifierType). Internal (not private) so tests reuse them instead of
// mirroring the values.
let GDK_SHIFT: UInt32 = 1 << 0
let GDK_CONTROL: UInt32 = 1 << 2
let GDK_ALT: UInt32 = 1 << 3
let GDK_SUPER: UInt32 = 1 << 26

/// Translate a GdkModifierType bitfield to ghostty's modifier flags.
func ghosttyMods(_ state: UInt32) -> ghostty_input_mods_e {
    var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if state & GDK_SHIFT != 0 { m |= GHOSTTY_MODS_SHIFT.rawValue }
    if state & GDK_CONTROL != 0 { m |= GHOSTTY_MODS_CTRL.rawValue }
    if state & GDK_ALT != 0 { m |= GHOSTTY_MODS_ALT.rawValue }
    if state & GDK_SUPER != 0 { m |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(rawValue: m)
}

/// Re-translates a hardware keycode through an XKB group for `latinKeyval`. Returns the group's
/// keyval, or `nil` when the group has no translation for the keycode. Injectable so the group
/// scan is unit-testable headless (the real implementation needs a live `GdkDisplay`).
typealias KeyGroupTranslator = (_ keycode: UInt32, _ state: UInt32, _ group: Int32) -> UInt32?

/// The production `KeyGroupTranslator`: `gdk_display_translate_key` on the default display.
/// A nil display (headless) or a failed translation yields nil, so `latinKeyval` passes through.
func gdkTranslateKey(keycode: UInt32, state: UInt32, group: Int32) -> UInt32? {
    guard let display = gdk_display_get_default() else { return nil }
    var keyval: guint = 0
    let ok = gdk_display_translate_key(display, keycode, GdkModifierType(rawValue: state), group,
                                       &keyval, nil, nil, nil)
    return ok != 0 ? keyval : nil
}

/// The lowered unicode character of a keyval (0 for a non-character keysym) — the shared
/// composition behind the Latin early-out, the group-scan accept, the Ctrl+C check, and `chord`.
@inline(__always) private func loweredUnicode(_ keyval: UInt32) -> guint32 {
    gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval))
}

/// Latin-script unicode blocks beyond ASCII: Latin-1 Supplement through Latin Extended-B
/// (0xA0–0x24F — German/French/Spanish/Nordic/Czech/Polish/Turkish accented letters, plus Latin-1
/// symbol keycaps like AZERTY `²`/`§`) and Latin Extended Additional (0x1E00–0x1EFF, Vietnamese).
/// A keyval in these ranges comes from a Latin layout and must NOT be re-routed by the group scan.
private func isLatinScriptUnicode(_ unicode: guint32) -> Bool {
    (0xA0...0x24F).contains(unicode) || (0x1E00...0x1EFF).contains(unicode)
}

/// Resolve the keyval to match app shortcuts against, independent of the active keyboard layout.
///
/// With a non-Latin layout active (e.g. Russian in a `us,ru` XKB setup) GDK reports the
/// layout-translated keyval, so Ctrl+T arrives as Ctrl+`е` (Cyrillic) and matches nothing in the
/// keymap's Latin vocabulary. When the event keyval carries no Latin character, re-translate the
/// HARDWARE keycode through the keyboard's XKB groups (0–3) and return the first keyval that
/// yields ASCII — the Latin layout, whichever group slot it occupies (handles both `us,ru` and
/// `ru,us` orders).
///
/// Two distinct conditions, deliberately not conflated:
/// - EARLY-OUT: the lowered unicode is ASCII (`< 0x80`, 0 INCLUDED, so non-character keysyms —
///   Escape/arrows/F-keys — return unchanged and never enter the scan) or a Latin-script character
///   (`isLatinScriptUnicode`). A Latin-layout keyval is always taken as-is, so an accented-letter
///   binding (`map ctrl+ü`) keeps matching and an AZERTY digit-row key (Ctrl+é) is never re-routed
///   onto the reserved Ctrl+2 chord. Zero overhead on Latin layouts, and the leader-abort/fallback
///   paths never see a translated value.
/// - SCAN-ACCEPT: `unicode != 0 && unicode < 0x80` — a group yielding no character must not win.
///
/// If no group yields ASCII (purely non-Latin config) or translation fails, the original keyval is
/// returned: behavior identical to no fallback at all. Feeds ONLY shortcut matching — terminal
/// text input flows through the separate IM/raw path with the raw keyval, so non-Latin typing
/// reaches the shell unchanged.
///
/// Known limits of this keyval-first matching (GTK-standard; upstream ghostty behaves the same):
/// a non-Latin key whose keyval is ALREADY a different ASCII character than the Latin group's
/// (Russian Shift+2 prints `"`, the Russian `/?` key prints `.`) early-outs on that character, so
/// such shifted/punctuation chords stay layout-dependent; and a binding deliberately using a
/// non-Latin letter (`map ctrl+ж`) cannot fire while a Latin group is configured, because the scan
/// rewrites the keyval before the matcher sees it.
func latinKeyval(keyval: UInt32, keycode: UInt32, state: UInt32,
                 translate: KeyGroupTranslator = gdkTranslateKey) -> UInt32 {
    let unicode = loweredUnicode(keyval)
    if unicode < 0x80 || isLatinScriptUnicode(unicode) { return keyval }
    for group: Int32 in 0...3 {
        guard let candidate = translate(keycode, state, group) else { continue }
        let u = loweredUnicode(candidate)
        if u != 0, u < 0x80 { return candidate }
    }
    return keyval
}

/// Whether a key press counts as an interrupt for attention-status clearing: Escape, or Ctrl+C
/// with no other modifier held. The `c` is resolved through `latinKeyval` so Ctrl+C is recognized
/// on a non-Latin layout, and the modifier guard runs FIRST so plain typing never pays the group
/// scan. Translator-injectable so the predicate is headless-testable (mirrors `latinKeyval`).
func isInterruptKey(keyval: UInt32, keycode: UInt32, state: UInt32,
                    translate: KeyGroupTranslator = gdkTranslateKey) -> Bool {
    if keyval == 0xFF1B { return true }
    guard state & GDK_CONTROL != 0, state & (GDK_SHIFT | GDK_ALT | GDK_SUPER) == 0 else { return false }
    let base = latinKeyval(keyval: keyval, keycode: keycode, state: state, translate: translate)
    return loweredUnicode(base) == 0x63
}

/// Translate a GTK key press (`keyval` + `GdkModifierType state`) into the shared, host-free
/// `agtermCore.Chord` the keymap matcher consumes — or `nil` when the press is not a bindable base key
/// (a bare modifier, Escape, or a function/navigation key with no unicode), so the caller can run its
/// arrow/page fallback or pass the key through to libghostty.
///
/// Mirrors the macOS `NSEvent -> Chord` contract: the base key is the UNSHIFTED, lowercased character
/// (so `Shift+D` yields `key == "d"` with `.shift` in `mods`), and the modifier set is built EXACTLY
/// (CapsLock/NumLock and other bits dropped) because the matcher compares `mods` by OptionSet equality.
func chord(fromKeyval keyval: UInt32, state: UInt32) -> Chord? {
    var mods: Modifier = []
    if state & GDK_CONTROL != 0 { mods.insert(.control) }
    if state & GDK_SHIFT != 0 { mods.insert(.shift) }
    if state & GDK_ALT != 0 { mods.insert(.option) }
    if state & GDK_SUPER != 0 { mods.insert(.command) }

    // The named keys parseKeybind accepts (with their keypad variants); Escape is the leader-abort and
    // is intentionally not a bindable base key.
    switch keyval {
    case 0xFF09: return Chord(mods: mods, key: "tab")
    case 0x20, 0xFF80: return Chord(mods: mods, key: "space")
    case 0xFF0D, 0xFF8D: return Chord(mods: mods, key: "return")
    case 0xFF08, 0xFFFF: return Chord(mods: mods, key: "delete")
    case 0xFF1B: return nil
    default: break
    }

    // GDK reports the shifted symbol as the keyval. Fold the common keyboard pairs back to their base
    // key so `shift+/`, `shift+=`, and `shift+5` match the same keymap vocabulary as macOS.
    let unshiftedKeyval: UInt32
    if mods.contains(.shift) {
        unshiftedKeyval = [
            0x21: 0x31, 0x40: 0x32, 0x23: 0x33, 0x24: 0x34, 0x25: 0x35,
            0x5E: 0x36, 0x26: 0x37, 0x2A: 0x38, 0x28: 0x39, 0x29: 0x30,
            0x5F: 0x2D, 0x2B: 0x3D, 0x7B: 0x5B, 0x7D: 0x5D, 0x7C: 0x5C,
            0x3A: 0x3B, 0x22: 0x27, 0x3C: 0x2C, 0x3E: 0x2E, 0x3F: 0x2F,
            0x7E: 0x60,
        ][keyval] ?? keyval
    } else {
        unshiftedKeyval = keyval
    }
    let u = loweredUnicode(unshiftedKeyval)
    guard u >= 0x20, u != 0x7F, let scalar = Unicode.Scalar(u) else { return nil }
    let key = String(scalar).lowercased()
    guard key.count == 1, key != " " else { return nil }
    return Chord(mods: mods, key: key)
}
