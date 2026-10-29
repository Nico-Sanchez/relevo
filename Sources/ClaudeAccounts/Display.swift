import ClaudeAccountsCore
import Foundation

enum Display {
    static func accountName(_ name: String?, id: String) -> String {
        name ?? String(localized: "Account \(String(id.prefix(8)))")
    }

    static func orgName(_ name: String?, location: Location?) -> String {
        if let name {
            return name
        }
        guard let location else { return String(localized: "Unknown organization") }
        return "org \(location.org.prefix(8))"
    }

    static func windowName(_ id: String) -> String {
        switch id {
        case "five_hour":
            return String(localized: "5 h")
        case "seven_day":
            return String(localized: "Week")
        default:
            guard id.hasPrefix("seven_day_") else { return id }
            return String(localized: "Week · \(id.dropFirst("seven_day_".count).capitalized)")
        }
    }

    static func message(for error: Error, names: [String: String]) -> String {
        let name = { (id: String) in accountName(names[id], id: id) }
        switch error {
        case AccountError.claudeRunning:
            return String(localized: "Claude is still open. Nothing changed.")
        case let AccountError.alreadyCurrent(id):
            return String(localized: "You're already on \(name(id)).")
        case let AccountError.noSavedLogin(id):
            return String(localized: "There's no saved login for \(name(id)).")
        case let AccountError.notSignedInto(id):
            return String(localized: "Claude isn't on \(name(id)). No sessions were moved.")
        case let AccountError.invalidAccount(id):
            return String(localized: "Invalid account: \(id).")
        case AccountError.unreadableConfig:
            return String(localized: "Couldn't read Claude's configuration. Nothing changed.")
        case UsageError.keychainDenied:
            return String(localized: "No access to the keychain.")
        case UsageError.noSession:
            return String(localized: "No saved session.")
        case let UsageError.http(status):
            return String(localized: "claude.ai answered \(status).")
        case UsageError.unreadable:
            return String(localized: "Unexpected answer from claude.ai.")
        default:
            return error.localizedDescription
        }
    }

    static func summary(of result: BringResult) -> String {
        var text = result.moved == 1
            ? String(localized: "Brought 1 session.")
            : String(localized: "Brought \(result.moved) sessions.")
        if result.kept == 1 {
            text += " " + String(localized: "1 was already there with the same id; I left it alone.")
        } else if result.kept > 1 {
            text += " " + String(localized: "\(result.kept) were already there with the same id; I left them alone.")
        }
        return text
    }
}

extension Account {
    var displayName: String { Display.accountName(name, id: id) }
    var displayOrg: String { Display.orgName(orgName, location: location) }
}

extension SessionGroup {
    var displayName: String {
        "\(Display.accountName(accountName, id: location.account)) · \(Display.orgName(orgName, location: location))"
    }
}

extension SessionSummary {
    var displayTitle: String { title.isEmpty ? String(localized: "Untitled") : title }
}
