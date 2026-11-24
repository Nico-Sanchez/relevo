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

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var code: [Substring]?
        var language: String?

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraph = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if let match = trimmed.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code {
            blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }
}
