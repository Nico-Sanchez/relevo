import Foundation
import Testing
@testable import RelevoCodeApp

@MainActor
@Suite struct ControlsTests {
    @Test func offersClaudesPermissionModesInItsOrder() {
        #expect(NewSessionView.modes.map(\.0) == ["default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"])
        #expect(NewSessionView.modes.map(\.1) == ["Manual", "Accept edits", "Plan", "Auto", "Don’t ask", "Bypass permissions"])
        #expect(Composer.modeName("manual") == "Manual")
        #expect(Composer.modeName("default") == "Manual")
    }

    @Test func namesEffortLevelsLikeClaude() {
        #expect(["low", "medium", "high", "xhigh", "max"].map(SessionControls.effortName) == ["Low", "Medium", "High", "Extra high", "Max"])
    }
}
