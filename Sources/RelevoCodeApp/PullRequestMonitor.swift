import Foundation
import RelevoCI
import RelevoCode

struct AutomatedMessage: Equatable, Sendable {
    let summary: String
    let text: String
}

@MainActor
@Observable
final class PullRequestMonitor {
    enum State: Equatable {
        case loading
        case loaded(PullRequest?)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var lastChecked: Date?
    private(set) var autofix = false
    private(set) var queued: [AutomatedMessage] = []

    private let directory: () -> URL
    private let isRepository: @Sendable (URL) -> Bool
    private let makeSource: @Sendable (URL) -> any PullRequestSource
    private let canDeliver: () -> Bool
    private let deliver: (AutomatedMessage) -> Void
    private let interval: Duration
    private var watch: Watch?
    private var polling: Task<Void, Never>?
    private var delivering: Task<Void, Never>?

    init(
        directory: @escaping () -> URL,
        isRepository: @escaping @Sendable (URL) -> Bool = { _ in true },
        makeSource: @escaping @Sendable (URL) -> any PullRequestSource,
        canDeliver: @escaping () -> Bool,
        deliver: @escaping (AutomatedMessage) -> Void,
        interval: Duration = .seconds(60)
    ) {
        self.directory = directory
        self.isRepository = isRepository
        self.makeSource = makeSource
        self.canDeliver = canDeliver
        self.deliver = deliver
        self.interval = interval
    }

    convenience init(session: Session, environment: [String: String]) {
        self.init(
            directory: { session.workingDirectory },
            isRepository: { GitDiff.isRepository($0, environment: environment) },
            makeSource: { GitHubCLI(directory: $0, environment: environment) },
            canDeliver: { session.canSend },
            deliver: { session.sendAutomated($0.text, summary: $0.summary) }
        )
    }

    var pullRequest: PullRequest? {
        if case .loaded(let pullRequest) = state { pullRequest } else { nil }
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(60))
            }
        }
        delivering = Task { [weak self] in
            while !Task.isCancelled {
                self?.flush()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        polling?.cancel()
        delivering?.cancel()
        polling = nil
        delivering = nil
    }

    func setAutofix(_ enabled: Bool) async {
        autofix = enabled
        watch = nil
        queued = []
        if enabled {
            await refresh()
        }
    }

    func refresh() async {
        let directory = directory()
        let isRepository = isRepository
        let source = makeSource(directory)
        let needsViewer = autofix && watch == nil
        let fetched = await Task.detached { () -> Result<(PullRequest?, String?), Error> in
            Result {
                guard isRepository(directory) else { throw NotAGitRepository() }
                return (try source.pullRequest(), needsViewer ? try source.viewer() : nil)
            }
        }.value
        lastChecked = .now
        switch fetched {
        case .failure(is NotAGitRepository):
            state = .failed(String(localized: "This folder isn't a git repository."))
        case .failure(let error):
            state = .failed(Self.describe(error))
        case .success(let (pullRequest, viewer)):
            state = .loaded(pullRequest)
            guard autofix else { return }
            if watch == nil, let viewer {
                watch = Watch(viewer: viewer)
            }
            let events = watch?.events(for: pullRequest) ?? []
            for event in events {
                queued.append(await message(for: event, source: source))
            }
            flush()
        }
    }

    func flush() {
        guard !queued.isEmpty, canDeliver() else { return }
        deliver(queued.removeFirst())
    }

    private func message(for event: Event, source: any PullRequestSource) async -> AutomatedMessage {
        var logs: [String: String] = [:]
        if case .checksFailed(let pullRequest, let checks) = event {
            logs = await Task.detached {
                var logs: [String: String] = [:]
                for check in checks {
                    logs[check.name] = try? source.failedLog(of: check, in: pullRequest)
                }
                return logs
            }.value
        }
        return AutomatedMessage(summary: Self.summary(of: event), text: event.message(logs: logs).content)
    }

    static func summary(of event: Event) -> String {
        let number = event.pullRequest.number
        switch event {
        case .checksFailed(_, let checks):
            return String(localized: "CI failed on PR #\(number): \(checks.map(\.name).joined(separator: ", "))")
        case .feedback(_, let items):
            return String(localized: "New review feedback on PR #\(number) from \(Set(items.map { "@\($0.author)" }).sorted().joined(separator: ", "))")
        case .conflict:
            return String(localized: "PR #\(number) has merge conflicts")
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? CommandError {
            return error.output.isEmpty ? String(localized: "gh exited with status \(Int(error.status)).") : error.output
        }
        return error.localizedDescription
    }
}
