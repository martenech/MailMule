import Foundation

/// "When a message matches the conditions, do the actions" – applied to new inbox mail,
/// or with `afterDays` to inbox threads that have waited that long.
public struct MailRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// All conditions must match (otherwise any one is enough).
    public var matchAll: Bool
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    /// Act on inbox threads older than this many days instead of when the mail arrives.
    public var afterDays: Int?
    /// Only this account; nil for all.
    public var accountID: String?
    /// Arriving mail is checked only when it is newer than the rule (older mail: "Spustiť teraz").
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, matchAll: Bool = true,
                conditions: [RuleCondition], actions: [RuleAction], afterDays: Int? = nil,
                accountID: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchAll = matchAll
        self.conditions = conditions
        self.actions = actions
        self.afterDays = afterDays
        self.accountID = accountID
        self.createdAt = createdAt
    }
}

public struct RuleCondition: Codable, Identifiable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case sender, recipient, subject, body, attachmentSize, hasAttachment, newsletter
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case contains, notContains, equals, endsWith, greaterThan
    }

    public var id: UUID
    public var field: Field
    public var op: Operator
    /// Text to look for; several alternatives separated by commas ("faktúra, invoice").
    /// For attachment size a number of megabytes.
    public var value: String

    public init(id: UUID = UUID(), field: Field, op: Operator = .contains, value: String = "") {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }
}

public enum RuleAction: Codable, Equatable, Hashable, Sendable {
    case archive
    case markRead
    case star
    case trash
    /// Arrives quietly: no banner or sound.
    case noNotification
    case tag(String)
    /// Server folder by mailbox name.
    case moveToFolder(String)
}

/// What a rule can look at besides the stored message.
public struct RuleContext: Sendable {
    public var message: StoredMessage
    /// The mail has a List-Unsubscribe header (newsletters, marketing, notifications).
    public var isNewsletter: Bool
    public var attachmentBytes: Int

    public init(message: StoredMessage, isNewsletter: Bool, attachmentBytes: Int) {
        self.message = message
        self.isNewsletter = isNewsletter
        self.attachmentBytes = attachmentBytes
    }

    public init(message: StoredMessage, mime: MIMEMessage?) {
        self.message = message
        isNewsletter = mime?.headers["List-Unsubscribe"] != nil || mime?.headers["List-Id"] != nil
        attachmentBytes = mime?.attachments.reduce(0) { $0 + $1.size } ?? 0
    }
}

public enum RuleEngine {
    public static func matches(_ rule: MailRule, _ context: RuleContext) -> Bool {
        if let account = rule.accountID, account != context.message.accountID { return false }
        let conditions = rule.conditions.filter { $0.field.needsNoValue || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !conditions.isEmpty else { return false }
        return rule.matchAll
            ? conditions.allSatisfy { matches($0, context) }
            : conditions.contains { matches($0, context) }
    }

    static func matches(_ condition: RuleCondition, _ context: RuleContext) -> Bool {
        let message = context.message
        switch condition.field {
        case .hasAttachment:
            return !message.attachments.isEmpty
        case .newsletter:
            return context.isNewsletter
        case .attachmentSize:
            let megabytes = Double(condition.value.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
            return Double(context.attachmentBytes) > megabytes * 1_000_000
        case .sender:
            return text(condition, in: [message.from?.address, message.from?.name].compactMap { $0 })
        case .recipient:
            return text(condition, in: (message.to + message.cc).flatMap { [$0.address, $0.name].compactMap { $0 } })
        case .subject:
            return text(condition, in: [message.subject])
        case .body:
            return text(condition, in: [message.bodyText])
        }
    }

    /// Text conditions: case- and diacritic-insensitive; comma-separated values are alternatives.
    private static func text(_ condition: RuleCondition, in haystacks: [String]) -> Bool {
        let needles = condition.value.split(separator: ",").map { fold(String($0)) }.filter { !$0.isEmpty }
        let folded = haystacks.map(fold)
        let hit: (String) -> Bool = { needle in
            folded.contains { value in
                switch condition.op {
                case .equals: value == needle
                case .endsWith: value.hasSuffix(needle)
                default: value.contains(needle)
                }
            }
        }
        return condition.op == .notContains ? !needles.contains(where: hit) : needles.contains(where: hit)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}

extension RuleCondition.Field {
    /// Conditions that are true or false by themselves (no value to type).
    public var needsNoValue: Bool { self == .hasAttachment || self == .newsletter }
}
