import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

// GDK keysyms used by the fixtures (pure library values — no display needed).
private let keyvalT: UInt32 = 0x74            // 't'
private let keyvalQ: UInt32 = 0x71            // 'q'
private let keyvalC: UInt32 = 0x63            // 'c'
private let keyvalFive: UInt32 = 0x35         // '5'
private let keyvalSlash: UInt32 = 0x2F        // '/'
private let keyvalEscape: UInt32 = 0xFF1B     // Escape (unicode 0)
private let keyvalLeft: UInt32 = 0xFF51       // Left arrow (unicode 0)
private let keyvalF1: UInt32 = 0xFFBE         // F1 (unicode 0)
private let keyvalUdiaeresis: UInt32 = 0xFC   // 'ü' (Latin-1, unicode 0xFC)
private let keyvalEacute: UInt32 = 0xE9       // 'é' (Latin-1, unicode 0xE9)
private let keyvalCcaron: UInt32 = 0x01E8     // 'č' (Latin-2 keysym, unicode 0x10D)
private let cyrillicIeLower: UInt32 = 0x06C5  // Cyrillic_ie 'е' (unicode 0x435)
private let cyrillicIeUpper: UInt32 = 0x06E5  // Cyrillic_IE 'Е'
private let cyrillicEs: UInt32 = 0x06D3       // Cyrillic_es 'с' (unicode 0x441) — the 'c' keycap
private let keyvalShiftL: UInt32 = 0xFFE1     // Shift_L (unicode 0 — must not win the scan)

/// Records what a fake translator was asked for.
private final class TranslatorSpy {
    var calls = 0
    var groups: [Int32] = []
    var keycodes: [UInt32] = []
    var states: [UInt32] = []
}

/// Builds a fake XKB-group translator from a `group -> keyval` table, recording invocations.
private func fakeTranslator(_ table: [Int32: UInt32], spy: TranslatorSpy? = nil) -> KeyGroupTranslator {
    { keycode, state, group in
        spy?.calls += 1
        spy?.groups.append(group)
        spy?.keycodes.append(keycode)
        spy?.states.append(state)
        return table[group]
    }
}

@Suite("latinKeyval XKB group fallback")
struct LatinKeyvalTests {
    @Test("ASCII keyvals pass through untouched without invoking the translator",
          arguments: [keyvalT, keyvalFive, keyvalSlash])
    func asciiEarlyOut(keyval: UInt32) {
        let spy = TranslatorSpy()
        let result = latinKeyval(keyval: keyval, keycode: 28, state: 4,
                                 translate: fakeTranslator([0: keyvalT], spy: spy))
        #expect(result == keyval)
        #expect(spy.calls == 0)
    }

    @Test("non-character keysyms (Escape, arrow, F-key) pass through without invoking the translator",
          arguments: [keyvalEscape, keyvalLeft, keyvalF1])
    func nonCharacterEarlyOut(keyval: UInt32) {
        let spy = TranslatorSpy()
        let result = latinKeyval(keyval: keyval, keycode: 9, state: 0,
                                 translate: fakeTranslator([0: keyvalT], spy: spy))
        #expect(result == keyval)
        #expect(spy.calls == 0)
    }

    @Test("Latin-script accented keyvals (German ü, French é, Czech č) pass through without the scan",
          arguments: [keyvalUdiaeresis, keyvalEacute, keyvalCcaron])
    func latinScriptEarlyOut(keyval: UInt32) {
        // A `de,us`/`fr,us` table: the scan WOULD find ASCII at another group, but a Latin-layout
        // keyval must be taken as-is so `map ctrl+ü` bindings keep matching (and AZERTY Ctrl+é is
        // never re-routed onto the reserved Ctrl+2 chord).
        let spy = TranslatorSpy()
        let result = latinKeyval(keyval: keyval, keycode: 34, state: 4,
                                 translate: fakeTranslator([0: keyval, 1: keyvalT], spy: spy))
        #expect(result == keyval)
        #expect(spy.calls == 0)
    }

    @Test("Cyrillic keyval resolves via group 0 in a us,ru layout")
    func usRuResolvesGroupZero() {
        let translate = fakeTranslator([0: keyvalT, 1: cyrillicIeLower])
        #expect(latinKeyval(keyval: cyrillicIeLower, keycode: 28, state: 4, translate: translate) == keyvalT)
    }

    @Test("Cyrillic keyval resolves via group 1 in a ru,us layout (scan order)")
    func ruUsResolvesGroupOne() {
        let translate = fakeTranslator([0: cyrillicIeLower, 1: keyvalT])
        #expect(latinKeyval(keyval: cyrillicIeLower, keycode: 28, state: 4, translate: translate) == keyvalT)
    }

    @Test("the first ASCII group wins and stops the scan (multi-Latin config)")
    func firstAsciiGroupWins() {
        let spy = TranslatorSpy()
        let result = latinKeyval(keyval: cyrillicIeLower, keycode: 28, state: 4,
                                 translate: fakeTranslator([0: keyvalT, 1: keyvalQ], spy: spy))
        #expect(result == keyvalT)
        #expect(spy.calls == 1)
    }

    @Test("the event's hardware keycode and modifier state are forwarded to the translator unmodified")
    func translatorReceivesKeycodeAndState() {
        let spy = TranslatorSpy()
        _ = latinKeyval(keyval: cyrillicIeLower, keycode: 28, state: 5,
                        translate: fakeTranslator([0: keyvalT], spy: spy))
        #expect(spy.keycodes == [28])
        #expect(spy.states == [5])
    }

    @Test("shifted (uppercase) Cyrillic keyval also resolves to the Latin group")
    func shiftedCyrillicResolves() {
        let translate = fakeTranslator([0: keyvalT, 1: cyrillicIeUpper])
        #expect(latinKeyval(keyval: cyrillicIeUpper, keycode: 28, state: 5, translate: translate) == keyvalT)
    }

    @Test("a group yielding a non-character keysym must not win the scan")
    func nonCharacterGroupSkipped() {
        let translate = fakeTranslator([0: keyvalShiftL, 1: keyvalT])
        #expect(latinKeyval(keyval: cyrillicIeLower, keycode: 28, state: 4, translate: translate) == keyvalT)
    }

    @Test("translator returning nil for every group falls back to the original keyval, scanning groups 0-3")
    func allGroupsNilFallsBack() {
        let spy = TranslatorSpy()
        let result = latinKeyval(keyval: cyrillicIeLower, keycode: 28, state: 4,
                                 translate: fakeTranslator([:], spy: spy))
        #expect(result == cyrillicIeLower)
        #expect(spy.calls == 4)
        #expect(spy.groups == [0, 1, 2, 3])
    }

    @Test("no group yielding ASCII (purely non-Latin config) falls back to the original keyval")
    func noAsciiGroupFallsBack() {
        let translate = fakeTranslator([0: cyrillicIeLower, 1: cyrillicIeUpper,
                                        2: cyrillicIeLower, 3: cyrillicIeUpper])
        #expect(latinKeyval(keyval: cyrillicIeLower, keycode: 28, state: 4, translate: translate) == cyrillicIeLower)
    }
}

@Suite("isInterruptKey attention-clear predicate")
struct IsInterruptKeyTests {
    @Test("Escape is an interrupt regardless of modifiers")
    func escapeIsInterrupt() {
        #expect(isInterruptKey(keyval: keyvalEscape, keycode: 9, state: 0, translate: fakeTranslator([:])))
        #expect(isInterruptKey(keyval: keyvalEscape, keycode: 9, state: GDK_CONTROL, translate: fakeTranslator([:])))
    }

    @Test("sole-Ctrl+C is an interrupt without invoking the translator (ASCII early-out)")
    func ctrlCIsInterrupt() {
        let spy = TranslatorSpy()
        #expect(isInterruptKey(keyval: keyvalC, keycode: 54, state: GDK_CONTROL,
                               translate: fakeTranslator([:], spy: spy)))
        #expect(spy.calls == 0)
    }

    @Test("Ctrl+C with an extra modifier is not an interrupt and never translates",
          arguments: [GDK_CONTROL | GDK_SHIFT, GDK_CONTROL | GDK_ALT])
    func extraModifierExcluded(state: UInt32) {
        let spy = TranslatorSpy()
        #expect(!isInterruptKey(keyval: keyvalC, keycode: 54, state: state,
                                translate: fakeTranslator([:], spy: spy)))
        #expect(spy.calls == 0)
    }

    @Test("a plain keypress without Ctrl never pays the group scan")
    func noCtrlNeverTranslates() {
        let spy = TranslatorSpy()
        #expect(!isInterruptKey(keyval: cyrillicEs, keycode: 54, state: 0,
                                translate: fakeTranslator([0: keyvalC], spy: spy)))
        #expect(spy.calls == 0)
    }

    @Test("Ctrl+`с` (Cyrillic es on the C keycap) is an interrupt via the Latin-group fallback")
    func ctrlCyrillicEsIsInterrupt() {
        #expect(isInterruptKey(keyval: cyrillicEs, keycode: 54, state: GDK_CONTROL,
                               translate: fakeTranslator([0: keyvalC, 1: cyrillicEs])))
    }

    @Test("Ctrl+`с` with no Latin group stays a non-interrupt")
    func ctrlCyrillicEsWithoutLatinGroup() {
        #expect(!isInterruptKey(keyval: cyrillicEs, keycode: 54, state: GDK_CONTROL,
                                translate: fakeTranslator([:])))
    }
}

@Suite("resolveShortcutKey chord routing")
struct ResolveShortcutKeyTests {
    @Test("Ctrl+Cyrillic `е` resolves to the Latin-group chord ctrl+t")
    func cyrillicResolvesToLatinChord() {
        let resolution = resolveShortcutKey(keyval: cyrillicIeLower, keycode: 28, state: GDK_CONTROL,
                                            translate: fakeTranslator([0: keyvalT, 1: cyrillicIeLower]))
        #expect(resolution == .chord(Chord(mods: [.control], key: "t"), matchKeyval: keyvalT))
    }

    @Test("with no Latin group the chord keeps the layout's own character")
    func noLatinGroupKeepsRawChord() {
        let resolution = resolveShortcutKey(keyval: cyrillicIeLower, keycode: 28, state: GDK_CONTROL,
                                            translate: fakeTranslator([:]))
        #expect(resolution == .chord(Chord(mods: [.control], key: "е"), matchKeyval: cyrillicIeLower))
    }

    @Test("a non-Chord key (arrow) routes to the fallback carrying its keyval")
    func arrowRoutesToFallback() {
        let resolution = resolveShortcutKey(keyval: keyvalLeft, keycode: 113, state: GDK_CONTROL | GDK_SHIFT,
                                            translate: fakeTranslator([:]))
        #expect(resolution == .fallback(matchKeyval: keyvalLeft))
    }
}
