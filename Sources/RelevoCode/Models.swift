import Foundation

public enum ModelCatalog {
    public static let recommendedEffort = "medium"

    public static func resolved(_ model: String?, in options: [ModelOption]) -> String? {
        if model == nil || model == "default" {
            return options.first { $0.value == "default" }?.resolvedModel
        }
        return options.first { $0.value == model }?.resolvedModel ?? model
    }

    public static func name(of model: String?, in options: [ModelOption]) -> String? {
        let target = resolved(model, in: options)
        let named = options.filter { $0.value != "default" }
        return named.first { ($0.resolvedModel ?? $0.value) == target }?.displayName
            ?? named.first { $0.value == model }?.displayName
    }

    public static func isCurrent(_ option: ModelOption, model: String?, in options: [ModelOption]) -> Bool {
        (option.resolvedModel ?? option.value) == resolved(model, in: options)
    }

    public static func primary(_ options: [ModelOption]) -> [ModelOption] {
        options.filter { $0.value != "default" && !$0.value.hasPrefix("claude-") }
    }

    public static func more(_ options: [ModelOption]) -> [ModelOption] {
        options.filter { $0.value.hasPrefix("claude-") }
    }

    public static func levels(for model: String?, in options: [ModelOption]) -> [String] {
        let target = resolved(model, in: options)
        return options.first { ($0.resolvedModel ?? $0.value) == target && !$0.effortLevels.isEmpty }?.effortLevels ?? []
    }

    public static func configuredEffort(in directory: URL, account: ClaudeAccount, model: String?) -> String? {
        let files = [
            directory.appending(path: ".claude/settings.local.json"),
            directory.appending(path: ".claude/settings.json"),
            account.folder.appending(path: "settings.json"),
        ]
        for file in files {
            guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let settings = JSONValue(object)
            if let model, let level = settings["modelSettings"]?[model]?["effortLevel"]?.string {
                return level
            }
            if let level = settings["effortLevel"]?.string {
                return level
            }
        }
        return nil
    }

    public static func probe(
        account: ClaudeAccount, environment: [String: String], executable: URL, folder: URL
    ) async -> (models: [ModelOption], applied: AppliedSettings?)? {
        await Task.detached {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--permission-prompt-tool", "stdio"]
            var environment = environment
            environment["CLAUDE_CONFIG_DIR"] = account.configDirectory?.path
            process.environment = environment
            process.currentDirectoryURL = folder
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let watchdog = Watchdog(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { watchdog.stop() }
            for (id, subtype) in [("init", "initialize"), ("settings", "get_settings")] {
                let request = Wire.controlRequest(id: id, ["subtype": subtype])
                if let data = try? JSONSerialization.data(withJSONObject: request) {
                    try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
                }
            }
            var models: [ModelOption]?
            var applied: AppliedSettings?
            var buffer = Data()
            while models == nil || applied == nil {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) else { continue }
                    let message = JSONValue(object)
                    guard message["type"]?.string == "control_response", let response = message["response"] else { continue }
                    let payload = response["response"] ?? .object([:])
                    switch response["request_id"]?.string {
                    case "init": models = Wire.sessionInfo(from: payload).models
                    case "settings": applied = Wire.appliedSettings(from: payload)
                    default: break
                    }
                }
            }
            try? input.fileHandleForWriting.close()
            watchdog.stop()
            process.waitUntilExit()
            guard let models else { return nil }
            return (models, applied)
        }.value
    }
}
