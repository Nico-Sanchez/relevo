import Foundation
import Testing
@testable import RelevoCode
@testable import RelevoCodeApp

@Suite struct TitleTests {
    @Test func fallsBackToTheFirstLineWithoutLinks() {
        #expect(SessionTitle.fallback(from: "Me ayudas a setupear esto? https://thinkingmachines.ai/inkling-2-mini") == "Me ayudas a setupear esto?")
        #expect(SessionTitle.fallback(from: "\n  Fix   the login\tbug \nwith details") == "Fix the login bug")
        #expect(SessionTitle.fallback(from: "https://example.com/only-a-link") == "https://example.com/only-a-link")
        let long = "Revisar por qué el shard cinco de los tests end to end falla siempre en saloons y arreglarlo"
        #expect(SessionTitle.fallback(from: long) == "Revisar por qué el shard cinco de los tests end to end falla…")
    }

    @Test func keepsOnlyTheTitleFromWhatTheModelWrites() {
        #expect(SessionTitle.clean("Configurar Inkling 2 mini\n") == "Configurar Inkling 2 mini")
        #expect(SessionTitle.clean("\n\"Debug the e2e shard.\"\nextra") == "Debug the e2e shard")
        #expect(SessionTitle.clean("**Fix login**") == "Fix login")
        #expect(SessionTitle.clean("   \n") == nil)
        #expect(SessionTitle.clean(String(repeating: "word ", count: 30)) == nil)
    }

    @Test func asksHaikuWithoutSavingASessionOrRunningTools() {
        let arguments = SessionTitle.arguments(for: "Fix the build")
        #expect(arguments.starts(with: ["-p", "--no-session-persistence", "--model", "haiku", "--tools", ""]))
        #expect(arguments.contains("--setting-sources"))
        #expect(arguments.last?.hasSuffix("Request:\nFix the build") == true)
    }

    @MainActor
    @Test func namesANewSessionAndRemembersIt() async {
        let model = AppModel(defaults: UserDefaults(suiteName: "relevo-tests-\(UUID().uuidString)")!)
        var asked: [String] = []
        model.titleMaker = { text, _ in
            asked.append(text)
            return "Configurar Inkling 2 mini"
        }
        let session = Session(configuration: SessionConfiguration(directory: URL(filePath: "/work/app")), accountName: "Ana")
        session.apply(.sessionStarted(sessionID: "s-1", model: nil, permissionMode: nil, directory: nil))

        await model.name(session, from: "Me ayudas a setupear esto?")

        #expect(asked == ["Me ayudas a setupear esto?"])
        #expect(session.title == "Configurar Inkling 2 mini")
        let past = PastSession(id: "s-1", file: URL(filePath: "/x"), directory: URL(filePath: "/work/app"), title: "Me ayudas a setupear esto?", lastActivity: .now, branch: nil)
        #expect(model.title(of: past) == "Configurar Inkling 2 mini")
    }
}
