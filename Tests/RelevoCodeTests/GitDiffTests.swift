import Foundation
import Testing
@testable import RelevoCode

@Suite struct GitDiffTests {
    @Test func parsesModifiedAddedDeletedRenamedAndBinaryFiles() {
        let diff = """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -3,3 +3,4 @@ struct App {
                 let a = 1
            -    let b = 2
            +    let b = 3
            +    let c = 4
                 let d = 5
            \\ No newline at end of file
            @@ -20 +21 @@
            -old
            +new
            diff --git a/README.md b/README.md
            new file mode 100644
            --- /dev/null
            +++ b/README.md
            @@ -0,0 +1,2 @@
            +# Title
            +Body
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/old/name.swift b/new/name.swift
            similarity index 100%
            rename from old/name.swift
            rename to new/name.swift
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ
            """

        let files = GitDiff.parse(diff)

        #expect(files.map(\.path) == ["Sources/App.swift", "README.md", "gone.txt", "new/name.swift", "logo.png"])
        #expect(files.map(\.change) == [.modified, .added, .deleted, .renamed, .modified])
        #expect(files[0].hunks.map(\.oldStart) == [3, 20])
        #expect(files[0].hunks.map(\.newStart) == [3, 21])
        #expect(files[0].hunks[0].lines == ["     let a = 1", "-    let b = 2", "+    let b = 3", "+    let c = 4", "     let d = 5"])
        #expect(files[0].additions == 3)
        #expect(files[0].deletions == 2)
        #expect(files[1].additions == 2)
        #expect(files[3].oldPath == "old/name.swift")
        #expect(files[3].hunks.isEmpty)
        #expect(files[4].isBinary)
    }

    @Test func readsUncommittedAndBranchChangesOfARealRepository() throws {
        let repository = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: repository) }
        let git = Git(directory: repository, environment: [:])
        func commit(_ message: String) throws {
            _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@localhost", "-c", "commit.gpgsign=false", "commit", "-qam", message])
        }
        _ = try git.run(["init", "-q", "-b", "main"])
        try "one\ntwo\n".write(to: repository.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        _ = try git.run(["add", "a.txt"])
        try commit("init")
        _ = try git.run(["switch", "-q", "-c", "feature"])
        try "one\nTWO\n".write(to: repository.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try commit("change two")
        try "one\nTWO\nthree\n".write(to: repository.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repository.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let uncommitted = try GitDiff.load(in: repository, scope: .uncommitted, environment: [:])
        #expect(uncommitted.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(uncommitted.files[0].hunks.flatMap(\.lines).filter { $0.hasPrefix("+") || $0.hasPrefix("-") } == ["+three"])
        #expect(uncommitted.files[1].change == .added)
        #expect(uncommitted.files[1].hunks.first?.lines == ["+new"])
        #expect(uncommitted.base == nil)

        let branch = try GitDiff.load(in: repository, scope: .branch, environment: [:])
        #expect(branch.base == "main")
        #expect(branch.files[0].hunks.flatMap(\.lines).filter { $0.hasPrefix("+") || $0.hasPrefix("-") } == ["-two", "+TWO", "+three"])
    }

    @Test func recognisesAFolderThatIsNotARepository() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "notes\n".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        #expect(!GitDiff.isRepository(folder))
        for scope in DiffScope.allCases {
            #expect(throws: NotAGitRepository.self) { try GitDiff.load(in: folder, scope: scope, environment: [:]) }
        }

        _ = try Git(directory: folder, environment: [:]).run(["init", "-q"])
        #expect(GitDiff.isRepository(folder))
    }

    @Test func knowsWhetherAFolderIsInsideARepository() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appending(path: "Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(!GitDiff.isRepository(nested))

        try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
        #expect(GitDiff.isRepository(folder))
        #expect(GitDiff.isRepository(nested))
    }
}
