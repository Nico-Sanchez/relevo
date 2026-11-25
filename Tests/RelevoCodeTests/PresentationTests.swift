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
        #expect(call("AskUserQuestion", ["questions": [["question": "Which color?"], ["question": "Which day?"]]]).summary(relativeTo: project) == "Which color? · Which day?")
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
            .paragraph("First line"),
            .list([.init(marker: "•", level: 0, text: "item one"), .init(marker: "•", level: 0, text: "item two")]),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .paragraph("Done"),
        ])
    }

    @Test func readsNestedOrderedAndContinuedListItems() {
        let text = """
            1. Install Ollama
            2. Pull the model
              - about 20 GB
              * with tools and vision
            continues the item above
            + **bold** item

            After the list
            """

        #expect(MarkdownBlock.parse(text) == [
            .list([
                .init(marker: "1.", level: 0, text: "Install Ollama"),
                .init(marker: "2.", level: 0, text: "Pull the model"),
                .init(marker: "◦", level: 1, text: "about 20 GB"),
                .init(marker: "◦", level: 1, text: "with tools and vision\ncontinues the item above"),
                .init(marker: "•", level: 0, text: "**bold** item"),
            ]),
            .paragraph("After the list"),
        ])
    }

    @Test func readsAReplyWithBoldListItemsAndATableWithAnEmptyCorner() {
        let text = """
            Inkling 2 Mini ya corre local en tu Mac y responde bien.

            **Qué instalé:**
            - **Ollama 0.40.18**, con Homebrew.
            - **El modelo `inkling-2-mini`** (20 GB).

            **Rendimiento medido en tu M3 Pro:**

            | | Resultado |
            |---|---|
            | Primera llamada | ~20 s |
            | Generación | 9–18 tokens/s |
            """

        #expect(MarkdownBlock.parse(text) == [
            .paragraph("Inkling 2 Mini ya corre local en tu Mac y responde bien."),
            .paragraph("**Qué instalé:**"),
            .list([.init(marker: "•", level: 0, text: "**Ollama 0.40.18**, con Homebrew."), .init(marker: "•", level: 0, text: "**El modelo `inkling-2-mini`** (20 GB).")]),
            .paragraph("**Rendimiento medido en tu M3 Pro:**"),
            .table(header: ["", "Resultado"], rows: [["Primera llamada", "~20 s"], ["Generación", "9–18 tokens/s"]]),
        ])
    }

    func tool(_ id: String, _ name: String, _ input: [String: Any] = [:], _ state: ToolCall.State = .done) -> ToolCall {
        var call = ToolCall(id: id, name: name, input: JSONValue(input))
        call.state = state
        return call
    }

    @Test func groupsToolCallsThatRunBackToBack() {
        let a = tool("t1", "Bash")
        let b = tool("t2", "Read")
        let c = tool("t3", "Edit")
        let items = [
            TranscriptItem(id: "u", kind: .user("Fix it")),
            TranscriptItem(id: "1", kind: .tool(a)),
            TranscriptItem(id: "2", kind: .tool(b)),
            TranscriptItem(id: "x", kind: .assistant("Found it.")),
            TranscriptItem(id: "3", kind: .tool(c)),
        ]

        #expect(TranscriptRow.rows(items) == [
            .item(items[0]),
            .tools(id: "1", calls: [a, b]),
            .item(items[3]),
            .item(items[4]),
        ])
    }

    @Test func summarizesAGroupByWhatItDid() {
        let calls = [
            tool("1", "Bash", ["command": "swift build"]),
            tool("2", "Read", ["file_path": "/a.swift"]),
            tool("3", "Bash", ["command": "swift test"]),
            tool("4", "Edit", ["file_path": "/a.swift"]),
            tool("5", "Edit", ["file_path": "/a.swift"]),
            tool("6", "Write", ["file_path": "/b.swift"]),
            tool("7", "Grep", ["pattern": "TODO"]),
            tool("8", "WebFetch", ["url": "https://example.com"]),
            tool("9", "TodoWrite"),
            tool("10", "Task"),
            tool("11", "mcp__x__y"),
        ]

        #expect(ToolActivity.summarize(calls) == [.commands(2), .reads(1), .edits(2), .searches, .web, .todos, .agents(1), .tools(1)])
    }

    @Test func showsTheStateThatMattersMostInAGroup() {
        #expect(ToolActivity.state(of: [tool("1", "Bash"), tool("2", "Bash", [:], .failed)]) == .failed)
        #expect(ToolActivity.state(of: [tool("1", "Bash", [:], .failed), tool("2", "Bash", [:], .running)]) == .running)
        #expect(ToolActivity.state(of: [tool("1", "Bash", [:], .running), tool("2", "Bash", [:], .awaitingPermission)]) == .awaitingPermission)
        #expect(ToolActivity.state(of: [tool("1", "Bash"), tool("2", "Read")]) == .done)
    }

    @Test func quotesTextIntoTheDraft() {
        #expect(Quote.insert("Ollama 0.40.18\n\nruns as a service", into: "") == "> Ollama 0.40.18\n>\n> runs as a service\n\n")
        #expect(Quote.insert("  20 GB ", into: "Why so big?\n") == "Why so big?\n\n> 20 GB\n\n")
    }

    @Test func splitsAMessageIntoQuotedAndOwnParts() {
        let message = "> Ollama 0.40.18\n>runs as a service\n\nWhy does it start at login?\n> 20 GB\nToo big"
        #expect(Quote.parts(of: message) == [
            MessagePart(quoted: true, text: "Ollama 0.40.18\nruns as a service"),
            MessagePart(quoted: false, text: "Why does it start at login?"),
            MessagePart(quoted: true, text: "20 GB"),
            MessagePart(quoted: false, text: "Too big"),
        ])
        #expect(Quote.parts(of: "No quotes here") == [MessagePart(quoted: false, text: "No quotes here")])
    }

    @Test func readsTablesQuotesAndRules() {
        let text = """
            | Model | Size |
            |:------|-----:|
            | Mini | 20 GB |
            | Max | 80 GB |
            > Support for looped models
            is new.

            ---
            | not | a table |
            """

        #expect(MarkdownBlock.parse(text) == [
            .table(header: ["Model", "Size"], rows: [["Mini", "20 GB"], ["Max", "80 GB"]]),
            .quote("Support for looped models\nis new."),
            .rule,
            .paragraph("| not | a table |"),
        ])
    }

    @Test func keepsAnUnclosedCodeBlockWhileItStreams() {
        #expect(MarkdownBlock.parse("Look:\n```\nhalf") == [.paragraph("Look:"), .code(language: nil, text: "half")])
    }
}
