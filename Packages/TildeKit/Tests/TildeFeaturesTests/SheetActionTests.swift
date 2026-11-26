import Testing
import TildeCore
import TildeDesign
@testable import TildeFeatures

/// Which sheet buttons answer to Return and Esc. A stray Return must never trust a host key or make another
/// consequential choice, and Esc must always be able to back out.
@Suite struct SheetActionTests {
    @Test func trustingAnUnknownHostKeyNeedsAClick() {
        #expect(UnknownHostAction.trust.role.bindsReturn == false)
        #expect(UnknownHostAction.trust.role == .confirmByClick)
        #expect(UnknownHostAction.trust.decision == .trustAndSave)
    }

    @Test func escapeRejectsAnUnknownHostKey() {
        #expect(UnknownHostAction.reject.role.bindsEscape)
        #expect(UnknownHostAction.reject.decision == .reject)
    }

    @Test func noUnknownHostAnswerIsBoundToReturn() {
        for action in UnknownHostAction.allCases {
            #expect(action.role.bindsReturn == false, "\(action.title) must not answer to Return")
        }
    }

    @Test func onlyTheSafeConfirmRoleBindsReturn() {
        #expect(TildeActionRole.confirm.bindsReturn)
        #expect(TildeActionRole.confirmByClick.bindsReturn == false)
        #expect(TildeActionRole.secondary.bindsReturn == false)
        #expect(TildeActionRole.destructive.bindsReturn == false)
        #expect(TildeActionRole.cancel.bindsReturn == false)
        #expect(TildeActionRole.cancel.bindsEscape)
    }

    @Test func aClickOnlyConfirmKeepsThePrimaryLook() {
        #expect(TildeActionRole.confirmByClick.look == .primary)
        #expect(TildeActionRole.confirm.look == .primary)
    }
}
