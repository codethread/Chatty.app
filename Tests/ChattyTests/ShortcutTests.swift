import AppKit
import Carbon.HIToolbox
import Testing
@testable import Chatty

struct ShortcutTests {
    @Test func twoLeftShiftReleasesTriggerOnceAndStartANewPair() {
        var gesture = DoubleShiftGesture()
        let results = [
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [.shift], time: 0),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [], time: 0.1),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [.shift], time: 0.2),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [], time: 0.3),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [], time: 0.4)
        ]
        #expect(results == [false, false, false, true, false])
    }

    @Test func slowRightShiftAndOtherModifiersDoNotTrigger() {
        var gesture = DoubleShiftGesture()
        let results = [
            gesture.consume(keyCode: UInt16(kVK_RightShift), flags: [], time: 1),
            gesture.consume(keyCode: UInt16(kVK_RightShift), flags: [], time: 1.1),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [], time: 2),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [], time: 3),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [.command], time: 3.1),
            gesture.consume(keyCode: UInt16(kVK_Shift), flags: [], time: 3.2)
        ]
        #expect(results.allSatisfy { !$0 })
    }

    @MainActor
    @Test func keyBindingsRequireAModifierAndRenderSpecialKeys() throws {
        func event(flags: NSEvent.ModifierFlags, code: UInt16, chars: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        #expect(KeyBinding(event: event(flags: [], code: 0, chars: "a")) == nil)
        let binding = try #require(KeyBinding(event: event(flags: [.command, .option], code: UInt16(kVK_Space), chars: " ")))
        #expect(binding.label == "⌥⌘Space")
        #expect(binding.carbonModifiers == UInt32(cmdKey | optionKey))
    }
}
