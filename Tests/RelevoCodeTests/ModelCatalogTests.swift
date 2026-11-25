import Foundation
import Testing
@testable import RelevoCode

@Suite struct ModelCatalogTests {
    let options = [
        ModelOption(value: "default", displayName: "Default (recommended)", description: nil, effortLevels: ["low", "medium", "high", "xhigh", "max"], resolvedModel: "claude-opus-5-5"),
        ModelOption(value: "opus", displayName: "Opus 5.5", description: nil, effortLevels: ["low", "medium", "high", "xhigh", "max"], resolvedModel: "claude-opus-5-5"),
        ModelOption(value: "fable", displayName: "Fable 5.2", description: nil, effortLevels: ["low", "medium", "high", "xhigh", "max"], resolvedModel: "claude-fable-5-2"),
        ModelOption(value: "haiku", displayName: "Haiku 5.5", description: nil, effortLevels: ["low", "medium", "high", "xhigh", "max"], resolvedModel: "claude-haiku-5-5"),
        ModelOption(value: "claude-opus-4-6", displayName: "Opus 4.6", description: nil, effortLevels: ["low", "medium", "high", "max"], resolvedModel: "claude-opus-4-6"),
        ModelOption(value: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", description: nil, effortLevels: [], resolvedModel: "claude-haiku-4-5-20251001"),
    ]

    @Test func namesTheDefaultModelByWhatItResolvesTo() {
        #expect(ModelCatalog.name(of: nil, in: options) == "Opus 5.5")
        #expect(ModelCatalog.name(of: "default", in: options) == "Opus 5.5")
        #expect(ModelCatalog.name(of: "fable", in: options) == "Fable 5.2")
        #expect(ModelCatalog.name(of: "claude-haiku-5-5", in: options) == "Haiku 5.5")
        #expect(ModelCatalog.name(of: "claude-opus-4-6", in: options) == "Opus 4.6")
        #expect(ModelCatalog.name(of: nil, in: []) == nil)
    }

    @Test func splitsCurrentModelsFromOlderOnes() {
        #expect(ModelCatalog.primary(options).map(\.displayName) == ["Opus 5.5", "Fable 5.2", "Haiku 5.5"])
        #expect(ModelCatalog.more(options).map(\.displayName) == ["Opus 4.6", "Haiku 4.5"])
        #expect(ModelCatalog.isCurrent(options[1], model: nil, in: options))
        #expect(!ModelCatalog.isCurrent(options[2], model: nil, in: options))
        #expect(ModelCatalog.isCurrent(options[2], model: "claude-fable-5-2", in: options))
    }

    @Test func offersTheEffortLevelsOfTheModelInUse() {
        #expect(ModelCatalog.levels(for: nil, in: options) == ["low", "medium", "high", "xhigh", "max"])
        #expect(ModelCatalog.levels(for: "claude-opus-4-6", in: options) == ["low", "medium", "high", "max"])
        #expect(ModelCatalog.levels(for: "claude-haiku-4-5-20251001", in: options).isEmpty)
    }

    @Test func readsTheEffortConfiguredForAFolderAndAccount() throws {
        let project = try temporaryFolder()
        let config = try temporaryFolder()
        let account = ClaudeAccount(configDirectory: config)
        #expect(ModelCatalog.configuredEffort(in: project, account: account, model: "claude-opus-5-5") == nil)

        try #"{"effortLevel":"high","modelSettings":{"claude-opus-5-5":{"effortLevel":"xhigh"}}}"#.write(to: config.appending(path: "settings.json"), atomically: true, encoding: .utf8)
        #expect(ModelCatalog.configuredEffort(in: project, account: account, model: "claude-opus-5-5") == "xhigh")
        #expect(ModelCatalog.configuredEffort(in: project, account: account, model: "claude-sonnet-5-5") == "high")

        try FileManager.default.createDirectory(at: project.appending(path: ".claude"), withIntermediateDirectories: true)
        try #"{"effortLevel":"low"}"#.write(to: project.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
        try #"{"effortLevel":"max"}"#.write(to: project.appending(path: ".claude/settings.local.json"), atomically: true, encoding: .utf8)
        #expect(ModelCatalog.configuredEffort(in: project, account: account, model: "claude-opus-5-5") == "max")
    }
}
