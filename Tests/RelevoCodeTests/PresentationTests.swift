import Foundation
import Testing
@testable import RelevoCode

@Suite struct PresentationTests {
    let project = URL(filePath: "/work/project")

    func call(_ name: String, _ input: [String: Any]) -> ToolCall {
        ToolCall(id: "t", name: name, input: JSONValue(input))
    }

    @Test func summarizesEachToolByWhatItTouches() {
        #expect(call("Bash", ["command": "swift test", "description": "Run tests"]).summary(relativeTo: project) == "swift test")
        #expect(call("Edit", ["file_path": "/work/project/Sources/App.swift"]).summary(relativeTo: project) == "Sources/App.swift")
        #expect(call("Read", ["file_path": "/etc/hosts"]).summary(relativeTo: project) == "/etc/hosts")
        #expect(call("Grep", ["pattern": "TODO", "path": "/work/project/Sources"]).summary(relativeTo: project) == "TODO in Sources")
        #expect(call("WebFetch", ["url": "https://example.com"]).summary(relativeTo: project) == "https://example.com")
        #expect(call("mcp__x__thing", ["b": "second", "a": "first"]).summary(relativeTo: project) == "first")
    }

    @Test func showsWhatAWriteAddsOnlyWhenThereIsNoPatch() {
        var write = call("Write", ["file_path": "/work/project/a.txt", "content": "hi"])
        #expect(write.addedText == "hi")
        write.patch = [DiffHunk(oldStart: 1, newStart: 1, lines: ["-a", "+b"])]
        #expect(write.addedText == nil)
    }

    @Test func describesWhatAPermissionWouldDo() {
        let edit = PermissionRequest(
            id: "1", toolName: "Edit", displayName: "Edit",
            input: JSONValue(["file_path": "/a", "old_string": "one\ntwo", "new_string": "three"]),
            description: nil, suggestions: [], toolUseID: nil
        )
        #expect(edit.detail == "-one\n-two\n+three")
    }

    @Test func splitsMarkdownIntoHeadingsParagraphsAndCode() {
        let text = """
            # Plan

            First line
            - item one
            - item two

            ```swift
            let x = 1

            print(x)
            ```
            Done
            """

        #expect(MarkdownBlock.parse(text) == [
            .heading(level: 1, text: "Plan"),
            .paragraph("First line\n- item one\n- item two"),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .paragraph("Done"),
        ])
    }

    @Test func keepsAnUnclosedCodeBlockWhileItStreams() {
        #expect(MarkdownBlock.parse("Look:\n```\nhalf") == [.paragraph("Look:"), .code(language: nil, text: "half")])
    }
}
