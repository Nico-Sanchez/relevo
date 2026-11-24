import Foundation

public struct PullRequest: Sendable, Equatable {
    public let number: Int
    public let title: String
    public let url: String
    public let state: String
    public let headRef: String
    public let headSha: String
    public let baseRef: String
    public let mergeable: String
    public let checks: [Check]
    public var feedback: [Feedback]

    public init(
        number: Int, title: String, url: String, state: String, headRef: String, headSha: String,
        baseRef: String, mergeable: String, checks: [Check], feedback: [Feedback]
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.headRef = headRef
        self.headSha = headSha
        self.baseRef = baseRef
        self.mergeable = mergeable
        self.checks = checks
        self.feedback = feedback
    }

    public var isOpen: Bool { state == "OPEN" }
    public var hasConflicts: Bool { mergeable == "CONFLICTING" }
    public var shortSha: String { String(headSha.prefix(7)) }

    public var repository: Repository? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return Repository(host: host, owner: String(parts[0]), name: String(parts[1]))
    }
}

public struct Repository: Sendable, Equatable {
    public let host: String
    public let owner: String
    public let name: String

    public var slug: String { "\(host)/\(owner)/\(name)" }
}

public struct Check: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case pending, passed, failed, skipped
    }

    public let name: String
    public let outcome: Outcome
    public let link: String?

    public init(name: String, outcome: Outcome, link: String?) {
        self.name = name
        self.outcome = outcome
        self.link = link
    }

    public var run: RunReference? {
        guard let link,
              let match = link.firstMatch(of: /\/actions\/runs\/(\d+)(?:\/job\/(\d+))?/) else { return nil }
        return RunReference(id: String(match.1), job: match.2.map(String.init))
    }
}

public struct RunReference: Sendable, Equatable {
    public let id: String
    public let job: String?
}

public struct Feedback: Sendable, Equatable {
    public let id: String
    public let author: String
    public let association: String?
    public let body: String
    public let url: String?
    public let location: String?
    public let verdict: String?

    public init(
        id: String, author: String, association: String?, body: String, url: String?,
        location: String? = nil, verdict: String? = nil
    ) {
        self.id = id
        self.author = author
        self.association = association
        self.body = body
        self.url = url
        self.location = location
        self.verdict = verdict
    }

    public var isFromCollaborator: Bool {
        ["OWNER", "MEMBER", "COLLABORATOR"].contains(association?.uppercased() ?? "")
    }
}

extension PullRequest {
    static let fields = "number,title,url,state,headRefName,headRefOid,baseRefName,mergeable,statusCheckRollup,comments,reviews"

    static func decode(_ data: Data) throws -> PullRequest {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let comments = (payload.comments ?? []).compactMap { comment -> Feedback? in
            guard comment.isMinimized != true, let author = comment.author?.login, !comment.body.isBlank else { return nil }
            return Feedback(id: comment.id, author: author, association: comment.authorAssociation, body: comment.body, url: comment.url)
        }
        let reviews = (payload.reviews ?? []).compactMap { review -> Feedback? in
            guard ["COMMENTED", "CHANGES_REQUESTED"].contains(review.state),
                  let author = review.author?.login, !review.body.isBlank else { return nil }
            return Feedback(
                id: review.id, author: author, association: review.authorAssociation, body: review.body, url: nil,
                verdict: review.state
            )
        }
        return PullRequest(
            number: payload.number,
            title: payload.title,
            url: payload.url,
            state: payload.state,
            headRef: payload.headRefName,
            headSha: payload.headRefOid,
            baseRef: payload.baseRefName,
            mergeable: payload.mergeable,
            checks: (payload.statusCheckRollup ?? []).map(\.check),
            feedback: comments + reviews
        )
    }

    static func decodeInlineComments(_ data: Data) throws -> [Feedback] {
        try String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(InlineComment.self, from: Data($0.utf8)) }
            .compactMap { comment in
                guard let author = comment.login, !comment.body.isBlank else { return nil }
                let location = comment.path.map { path in comment.line.map { "\(path):\($0)" } ?? path }
                return Feedback(
                    id: "inline-\(comment.id)", author: author, association: comment.association, body: comment.body,
                    url: comment.url, location: location
                )
            }
    }

    static let inlineCommentsFilter =
        ".[] | {id, login: .user.login, association: .author_association, body, path, line: (.line // .original_line), url: .html_url}"

    private struct Payload: Decodable {
        struct Author: Decodable {
            let login: String?
        }

        struct Rollup: Decodable {
            enum CodingKeys: String, CodingKey {
                case kind = "__typename"
                case name, status, conclusion, detailsUrl, context, state, targetUrl
            }

            let kind: String
            let name: String?
            let status: String?
            let conclusion: String?
            let detailsUrl: String?
            let context: String?
            let state: String?
            let targetUrl: String?

            var check: Check {
                if kind == "StatusContext" {
                    return Check(name: context ?? "status", outcome: Self.outcome(ofStatus: state), link: targetUrl)
                }
                let outcome = status == "COMPLETED" ? Self.outcome(ofConclusion: conclusion) : .pending
                return Check(name: name ?? "check", outcome: outcome, link: detailsUrl)
            }

            static func outcome(ofConclusion conclusion: String?) -> Check.Outcome {
                switch conclusion {
                case "SUCCESS": .passed
                case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE": .failed
                default: .skipped
                }
            }

            static func outcome(ofStatus state: String?) -> Check.Outcome {
                switch state {
                case "SUCCESS": .passed
                case "FAILURE", "ERROR": .failed
                default: .pending
                }
            }
        }

        struct Comment: Decodable {
            let id: String
            let author: Author?
            let authorAssociation: String?
            let body: String
            let url: String?
            let isMinimized: Bool?
        }

        struct Review: Decodable {
            let id: String
            let author: Author?
            let authorAssociation: String?
            let body: String
            let state: String
        }

        let number: Int
        let title: String
        let url: String
        let state: String
        let headRefName: String
        let headRefOid: String
        let baseRefName: String
        let mergeable: String
        let statusCheckRollup: [Rollup]?
        let comments: [Comment]?
        let reviews: [Review]?
    }

    private struct InlineComment: Decodable {
        let id: Int
        let login: String?
        let association: String?
        let body: String
        let path: String?
        let line: Int?
        let url: String?
    }
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}
