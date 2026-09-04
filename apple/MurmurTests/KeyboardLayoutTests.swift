import XCTest

import MurmurKeyboardCore

/// The layout is a lookup table, so the test is a lookup table too: every cap on every page is
/// asserted to type exactly itself (and its uppercase under shift). A key that types the wrong
/// character is the one bug a user would find in the first ten seconds.
final class KeyboardLayoutTests: XCTestCase {
    /// The caps of each page, row by row, as the design spec draws them.
    private let expected: [KeyboardPage: [String]] = [
        .letters: ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
        .numbers: ["1234567890", "-/:;()$&@\"", ".,?!'"],
        .symbols: ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"],
    ]

    // MARK: - Rows

    func testLettersRows() {
        let rows = KeyboardLayout.rows(for: .letters)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], caps("qwertyuiop"))
        XCTAssertEqual(rows[1], caps("asdfghjkl"))
        XCTAssertEqual(rows[2], [.shift] + caps("zxcvbnm") + [.delete])
        XCTAssertEqual(rows[3], [.numbers, .globe, .mic, .space, .return])
    }

    func testNumbersRows() {
        let rows = KeyboardLayout.rows(for: .numbers)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], caps("1234567890"))
        XCTAssertEqual(rows[1], caps("-/:;()$&@\""))
        XCTAssertEqual(rows[2], [.symbols] + caps(".,?!'") + [.delete])
        XCTAssertEqual(rows[3], [.letters, .globe, .mic, .space, .return])
    }

    func testSymbolsRows() {
        let rows = KeyboardLayout.rows(for: .symbols)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], caps("[]{}#%^*+="))
        XCTAssertEqual(rows[1], caps("_\\|~<>€£¥•"))
        XCTAssertEqual(rows[2], [.numbers] + caps(".,?!'") + [.delete])
        XCTAssertEqual(rows[3], [.letters, .globe, .mic, .space, .return])
    }

    /// The bottom row is the same shape everywhere, with the mic immediately left of space.
    func testEveryPageEndsWithTheSameBottomRowShape() {
        for page in KeyboardPage.allCases {
            let bottom = KeyboardLayout.rows(for: page).last
            XCTAssertEqual(bottom?.count, 5, "\(page)")
            XCTAssertEqual(bottom?[1], .globe, "\(page)")
            XCTAssertEqual(bottom?[2], .mic, "\(page)")
            XCTAssertEqual(bottom?[3], .space, "\(page)")
            XCTAssertEqual(bottom?[4], .return, "\(page)")
        }
    }

    // MARK: - text(for:shift:)

    /// Every character key on every page types its own cap unshifted.
    func testEveryCharKeyTypesItsCapUnshifted() {
        for (page, rows) in expected {
            let keys = KeyboardLayout.rows(for: page).flatMap { $0 }.filter { key in
                if case .char = key { return true }
                return false
            }
            XCTAssertEqual(keys.count, rows.joined().count, "\(page)")
            for (key, cap) in zip(keys, rows.joined()) {
                XCTAssertEqual(KeyboardLayout.text(for: key, shift: .off), String(cap), "\(page) \(cap)")
            }
        }
    }

    /// Shift uppercases letters and leaves digits and symbols exactly as they are.
    func testShiftUppercasesLettersOnly() {
        for shift in [ShiftState.on, .capsLock] {
            for cap in "qwertyuiopasdfghjklzxcvbnm" {
                XCTAssertEqual(
                    KeyboardLayout.text(for: .char(String(cap)), shift: shift),
                    String(cap).uppercased()
                )
            }
            for page in [KeyboardPage.numbers, .symbols] {
                for key in KeyboardLayout.rows(for: page).flatMap({ $0 }) {
                    guard case let .char(cap) = key else { continue }
                    XCTAssertEqual(KeyboardLayout.text(for: key, shift: shift), cap, "\(page) \(cap)")
                }
            }
        }
    }

    func testSpaceAndReturnText() {
        for shift in ShiftState.allCases {
            XCTAssertEqual(KeyboardLayout.text(for: .space, shift: shift), " ")
            XCTAssertEqual(KeyboardLayout.text(for: .return, shift: shift), "\n")
        }
    }

    func testNonTextKeysTypeNothing() {
        for key in [Key.shift, .delete, .numbers, .symbols, .letters, .globe, .mic] {
            for shift in ShiftState.allCases {
                XCTAssertNil(KeyboardLayout.text(for: key, shift: shift), "\(key)")
            }
        }
    }

    // MARK: - Shift state

    func testSingleTapTogglesShift() {
        var state = KeyboardState()
        state.tapShift(now: 0)
        XCTAssertEqual(state.shift, .on)
        state.tapShift(now: 10)
        XCTAssertEqual(state.shift, .off)
    }

    func testDoubleTapWithinTheWindowLocksCaps() {
        var state = KeyboardState()
        state.tapShift(now: 0)
        state.tapShift(now: 0.2)
        XCTAssertEqual(state.shift, .capsLock)
    }

    /// Just inside the window locks, just outside toggles. The boundary itself is left alone:
    /// no real tap lands on it, and float seconds do not compare equal to it anyway.
    func testTheDoubleTapWindowEndsWhereItSays() {
        var fast = KeyboardState()
        fast.tapShift(now: 1)
        fast.tapShift(now: 1 + KeyboardState.doubleTapWindow - 0.05)
        XCTAssertEqual(fast.shift, .capsLock)

        var slow = KeyboardState()
        slow.tapShift(now: 1)
        slow.tapShift(now: 1 + KeyboardState.doubleTapWindow + 0.05)
        XCTAssertEqual(slow.shift, .off)
    }

    func testTwoSlowTapsDoNotLockCaps() {
        var state = KeyboardState()
        state.tapShift(now: 0)
        state.tapShift(now: 0.4)
        XCTAssertEqual(state.shift, .off)
    }

    /// A tap while caps lock is on always releases it, even a fast one — otherwise a third
    /// quick tap would leave the user stuck in capitals.
    func testTapWhileCapsLockedTurnsItOff() {
        var state = KeyboardState()
        state.tapShift(now: 0)
        state.tapShift(now: 0.1)
        XCTAssertEqual(state.shift, .capsLock)
        state.tapShift(now: 0.2)
        XCTAssertEqual(state.shift, .off)
    }

    func testOneShotShiftFallsAwayAfterOneInsert() {
        var state = KeyboardState()
        state.tapShift(now: 0)
        state.didInsert("A")
        XCTAssertEqual(state.shift, .off)
    }

    func testCapsLockSurvivesInserts() {
        var state = KeyboardState()
        state.tapShift(now: 0)
        state.tapShift(now: 0.1)
        state.didInsert("A")
        state.didInsert("B")
        XCTAssertEqual(state.shift, .capsLock)
    }

    func testInsertingNothingLeavesShiftArmed() {
        var state = KeyboardState()
        state.tapShift(now: 0)
        state.didInsert("")
        XCTAssertEqual(state.shift, .on)
    }

    // MARK: - autoShift

    func testAutoShiftAtDocumentStart() {
        XCTAssertEqual(KeyboardState.autoShift(contextBefore: nil), .on)
        XCTAssertEqual(KeyboardState.autoShift(contextBefore: ""), .on)
    }

    func testAutoShiftAfterSentenceEnds() {
        for context in ["Hello. ", "Hello! ", "Hello? ", "Hello\n"] {
            XCTAssertEqual(KeyboardState.autoShift(contextBefore: context), .on, context.debugDescription)
        }
    }

    func testAutoShiftOffMidSentence() {
        for context in ["Hello", "Hello ", "Hello.", "Hello,  ", "3.14"] {
            XCTAssertEqual(KeyboardState.autoShift(contextBefore: context), .off, context.debugDescription)
        }
    }

    private func caps(_ s: String) -> [Key] {
        s.map { .char(String($0)) }
    }
}
