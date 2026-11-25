import Foundation
import Testing
@testable import RelevoCode
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

    @Test func describesAGroupOfToolsInWords() {
        let calls = [
            ToolCall(id: "1", name: "Bash", input: .object([:])),
            ToolCall(id: "2", name: "Bash", input: .object([:])),
            ToolCall(id: "3", name: "Read", input: JSONValue(["file_path": "/a.swift"])),
            ToolCall(id: "4", name: "Edit", input: JSONValue(["file_path": "/a.swift"])),
            ToolCall(id: "5", name: "Edit", input: JSONValue(["file_path": "/b.swift"])),
        ]
        let summary = ToolGroupView.summary(of: calls)

        #expect(summary.hasPrefix("Ran 2 commands, read a file"))
        #expect(summary.hasSuffix("edited 2 files"))
    }
}
