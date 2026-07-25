import Foundation
import Testing
@testable import AgtermLinux

// GDK keysyms used by the fixtures (pure library values — no display needed).
private let keyvalT: UInt32 = 0x74            // 't'
private let keyvalFive: UInt32 = 0x35         // '5'
private let keyvalSlash: UInt32 = 0x2F        // '/'
private let keyvalEscape: UInt32 = 0xFF1B     // Escape (unicode 0)
private let keyvalLeft: UInt32 = 0xFF51       // Left arrow (unicode 0)
private let keyvalF1: UInt32 = 0xFFBE         // F1 (unicode 0)
private let cyrillicIeLower: UInt32 = 0x06C5  // Cyrillic_ie 'е' (unicode 0x435)
private let cyrillicIeUpper: UInt32 = 0x06E5  // Cyrillic_IE 'Е'
private let keyvalShiftL: UInt32 = 0xFFE1     // Shift_L (unicode 0 — must not win the scan)

/// Records what a fake translator was asked for.
private final class TranslatorSpy {
    var calls = 0
    var groups: [Int32] = []
}

/// Builds a fake XKB-group translator from a `group -> keyval` table, recording invocations.
private func fakeTranslator(_ table: [Int32: UInt32], spy: TranslatorSpy? = nil) -> KeyGroupTranslator {
    { _, _, group in
        spy?.calls += 1
        spy?.groups.append(group)
        return table[group]
    }
}

@Suite("latinKeyval XKB group fallback")
struct LatinKeyvalTests {
    @Test("ASCII keyvals pass through untouched without invoking the translator",
          arguments: [keyvalT, keyvalFive, keyvalSlash])
    func asciiEarlyOut(keyval: UInt32) {
        let spy = TranslatorSpy()
        let result = latinKeyval(keyval, keycode: 28, state: 4,
                                 translate: fakeTranslator([0: keyvalT], spy: spy))
        #expect(result == keyval)
        #expect(spy.calls == 0)
    }

    @Test("non-character keysyms (Escape, arrow, F-key) pass through without invoking the translator",
          arguments: [keyvalEscape, keyvalLeft, keyvalF1])
    func nonCharacterEarlyOut(keyval: UInt32) {
        let spy = TranslatorSpy()
        let result = latinKeyval(keyval, keycode: 9, state: 0,
                                 translate: fakeTranslator([0: keyvalT], spy: spy))
        #expect(result == keyval)
        #expect(spy.calls == 0)
    }

    @Test("Cyrillic keyval resolves via group 0 in a us,ru layout")
    func usRuResolvesGroupZero() {
        let translate = fakeTranslator([0: keyvalT, 1: cyrillicIeLower])
        #expect(latinKeyval(cyrillicIeLower, keycode: 28, state: 4, translate: translate) == keyvalT)
    }

    @Test("Cyrillic keyval resolves via group 1 in a ru,us layout (scan order)")
    func ruUsResolvesGroupOne() {
        let translate = fakeTranslator([0: cyrillicIeLower, 1: keyvalT])
        #expect(latinKeyval(cyrillicIeLower, keycode: 28, state: 4, translate: translate) == keyvalT)
    }

    @Test("shifted (uppercase) Cyrillic keyval also resolves to the Latin group")
    func shiftedCyrillicResolves() {
        let translate = fakeTranslator([0: keyvalT, 1: cyrillicIeUpper])
        #expect(latinKeyval(cyrillicIeUpper, keycode: 28, state: 5, translate: translate) == keyvalT)
    }

    @Test("a group yielding a non-character keysym must not win the scan")
    func nonCharacterGroupSkipped() {
        let translate = fakeTranslator([0: keyvalShiftL, 1: keyvalT])
        #expect(latinKeyval(cyrillicIeLower, keycode: 28, state: 4, translate: translate) == keyvalT)
    }

    @Test("translator returning nil for every group falls back to the original keyval, scanning groups 0-3")
    func allGroupsNilFallsBack() {
        let spy = TranslatorSpy()
        let result = latinKeyval(cyrillicIeLower, keycode: 28, state: 4,
                                 translate: fakeTranslator([:], spy: spy))
        #expect(result == cyrillicIeLower)
        #expect(spy.calls == 4)
        #expect(spy.groups == [0, 1, 2, 3])
    }

    @Test("no group yielding ASCII (purely non-Latin config) falls back to the original keyval")
    func noAsciiGroupFallsBack() {
        let translate = fakeTranslator([0: cyrillicIeLower, 1: cyrillicIeUpper,
                                        2: cyrillicIeLower, 3: cyrillicIeUpper])
        #expect(latinKeyval(cyrillicIeLower, keycode: 28, state: 4, translate: translate) == cyrillicIeLower)
    }
}
