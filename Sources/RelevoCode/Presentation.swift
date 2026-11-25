import Foundation

extension ToolCall {
    public func summary(relativeTo directory: URL) -> String {
        let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string
        switch name {
        case "Bash":
            return input["command"]?.string ?? ""
        case "Grep", "Glob":
            return [input["pattern"]?.string, path.map { relative($0, to: directory) }].compactMap { $0 }.joined(separator: " in ")
        case "WebFetch":
            return input["url"]?.string ?? ""
        case "WebSearch":
            return input["query"]?.string ?? ""
        case "Task", "Agent":
            return input["description"]?.string ?? ""
        case "AskUserQuestion":
            return (input["questions"]?.array ?? []).compactMap { $0["question"]?.string }.joined(separator: " · ")
        default:
            if let path {
                return relative(path, to: directory)
            }
            return firstString(in: input) ?? ""
        }
    }

    public var addedText: String? {
        guard patch.isEmpty, name == "Write" else { return nil }
        return input["content"]?.string
    }

    private func relative(_ path: String, to directory: URL) -> String {
        let base = directory.standardizedFileURL.path
        let standardized = URL(filePath: path).standardizedFileURL.path
        guard standardized.hasPrefix(base + "/") else { return URL(filePath: path).abbreviatingHome }
        return String(standardized.dropFirst(base.count + 1))
    }

    private func firstString(in value: JSONValue) -> String? {
        guard case .object(let values) = value else { return value.string }
        return values.keys.sorted().lazy.compactMap { values[$0]?.string }.first
    }
}

extension PermissionRequest {
    public var detail: String {
        switch toolName {
        case "Bash":
            return input["command"]?.string ?? ""
        case "Write":
            return input["content"]?.string ?? ""
        case "Edit":
            let old = input["old_string"]?.string ?? ""
            let new = input["new_string"]?.string ?? ""
            return (old.split(separator: "\n", omittingEmptySubsequences: false).map { "-\($0)" }
                + new.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" }).joined(separator: "\n")
        default:
            return input.prettyText
        }
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case list([ListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    public struct ListItem: Equatable, Sendable {
        public let marker: String
        public let level: Int
        public var text: String
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var items: [ListItem] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [Substring]?
        var language: String?

        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            if !items.isEmpty {
                blocks.append(.list(items))
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
            }
            if !table.isEmpty {
                blocks.append(tableBlock(table))
            }
            paragraph = []
            items = []
            quote = []
            table = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if let match = trimmed.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                flush()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if trimmed.wholeMatch(of: /(-{3,}|\*{3,}|_{3,})/) != nil, paragraph.isEmpty {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                if table.isEmpty {
                    flush()
                }
                table.append(trimmed)
            } else if trimmed.hasPrefix(">") {
                if quote.isEmpty {
                    flush()
                }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(line) {
                if items.isEmpty {
                    flush()
                }
                items.append(item)
            } else if !items.isEmpty {
                items[items.count - 1].text += "\n" + trimmed
            } else if !quote.isEmpty {
                quote.append(trimmed)
            } else {
                if !table.isEmpty {
                    flush()
                }
                paragraph.append(line)
            }
        }
        if let lines = code {
            blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func listItem(_ line: Substring) -> ListItem? {
        guard let match = line.wholeMatch(of: /( *)([-*+]|(\d{1,9})[.)])\s+(.*)/) else { return nil }
        let level = match.1.count / 2
        let marker = match.3.map { "\($0)." } ?? (level == 0 ? "•" : "◦")
        return ListItem(marker: marker, level: level, text: String(match.4))
    }

    private static func tableBlock(_ lines: [String]) -> MarkdownBlock {
        let rows = lines.map { line in
            var cells = Substring(line)
            if cells.hasPrefix("|") {
                cells = cells.dropFirst()
            }
            if cells.hasSuffix("|") {
                cells = cells.dropLast()
            }
            return cells.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let separator = rows.count > 1 && rows[1].allSatisfy { $0.wholeMatch(of: /:?-+:?/) != nil }
        guard separator else { return .paragraph(lines.joined(separator: "\n")) }
        return .table(header: rows[0], rows: Array(rows.dropFirst(2)))
    }
}

public struct MessagePart: Equatable, Sendable {
    public let quoted: Bool
    public let text: String
}

public enum Quote {
    public static func insert(_ text: String, into draft: String) -> String {
        let quoted = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (current.isEmpty ? "" : current + "\n\n") + quoted + "\n\n"
    }

    public static func parts(of message: String) -> [MessagePart] {
        var parts: [MessagePart] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let quoted = line.hasPrefix(">")
            let text = quoted ? String(line.dropFirst().drop { $0 == " " }) : String(line)
            if let last = parts.last, last.quoted == quoted {
                parts[parts.count - 1] = MessagePart(quoted: quoted, text: last.text + "\n" + text)
            } else {
                parts.append(MessagePart(quoted: quoted, text: text))
            }
        }
        return parts.compactMap { part in
            let text = part.text.trimmingCharacters(in: .newlines)
            return text.isEmpty ? nil : MessagePart(quoted: part.quoted, text: text)
        }
    }
}
