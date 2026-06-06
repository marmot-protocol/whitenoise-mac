import Foundation

struct AccountItem: Identifiable, Hashable {
    let id: String
    let accountRef: String
    let displayName: String
    let accountIdHex: String
    let npub: String?
    let initials: String
    let pictureURL: String?
    let localSigning: Bool
    let isRunning: Bool

    init(
        id: String,
        accountRef: String,
        displayName: String,
        accountIdHex: String,
        npub: String? = nil,
        initials: String? = nil,
        pictureURL: String? = nil,
        localSigning: Bool = true,
        isRunning: Bool = true
    ) {
        self.id = id
        self.accountRef = accountRef
        self.displayName = displayName
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.initials = initials ?? DisplayText.initials(for: displayName, fallback: accountIdHex)
        self.pictureURL = pictureURL
        self.localSigning = localSigning
        self.isRunning = isRunning
    }
}

struct ChatItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let preview: String
    let updatedAt: Date?
    let avatarSeed: String
    let pictureURL: String?
    let unreadCount: Int

    var timestampLabel: String {
        guard let updatedAt else { return "" }
        return DisplayText.relativeTimestamp(for: updatedAt)
    }
}

struct ChatPeerProfile: Hashable {
    let accountIdHex: String
    let displayName: String?
    let pictureURL: String?
}

struct MessageReaction: Identifiable, Hashable {
    let emoji: String
    let count: Int
    let isOwn: Bool

    var id: String { emoji }

    var label: String {
        count > 1 ? "\(emoji) \(count)" : emoji
    }
}

struct MessageReplyContext: Hashable {
    let targetMessageId: String
    let senderName: String
    let body: String
}

struct MessageItem: Identifiable, Hashable {
    let id: String
    let senderAccountIdHex: String
    let senderName: String
    let senderPictureURL: String?
    let body: String
    let sentAt: Date
    let isOutgoing: Bool
    let reactions: [MessageReaction]
    let replyContext: MessageReplyContext?

    init(
        id: String,
        senderAccountIdHex: String? = nil,
        senderName: String,
        senderPictureURL: String? = nil,
        body: String,
        sentAt: Date,
        isOutgoing: Bool,
        reactions: [MessageReaction] = [],
        replyContext: MessageReplyContext? = nil
    ) {
        self.id = id
        self.senderAccountIdHex = senderAccountIdHex ?? senderName
        self.senderName = senderName
        self.senderPictureURL = senderPictureURL
        self.body = body
        self.sentAt = sentAt
        self.isOutgoing = isOutgoing
        self.reactions = reactions
        self.replyContext = replyContext
    }

    var timeLabel: String {
        DisplayText.messageTimestamp(for: sentAt)
    }

    var statusLabel: String? {
        isOutgoing ? L10n.string("Sent") : nil
    }
}

enum WorkspaceSelection: Equatable {
    case chat(String)
    case settings(SettingsPage)
}

enum SettingsPage: Equatable {
    case overview
    case accounts
    case profile
    case identityKeys
    case relays
    case keyPackages
    case appearance
    case notifications
    case developerMode

    static let sidebarPages: [SettingsPage] = [
        .profile,
        .accounts,
        .identityKeys,
        .relays,
        .keyPackages,
        .appearance,
        .notifications,
        .developerMode
    ]

    var title: String {
        switch self {
        case .overview:
            L10n.string("Settings")
        case .accounts:
            L10n.string("Accounts")
        case .profile:
            L10n.string("Profile")
        case .identityKeys:
            L10n.string("Identity & Keys")
        case .relays:
            L10n.string("Relays")
        case .keyPackages:
            L10n.string("Key Packages")
        case .appearance:
            L10n.string("Appearance")
        case .notifications:
            L10n.string("Notifications")
        case .developerMode:
            L10n.string("Developer mode")
        }
    }

    var sidebarSubtitle: String {
        switch self {
        case .overview:
            L10n.string("Settings home")
        case .accounts:
            L10n.string("Switch identities")
        case .profile:
            L10n.string("Public display info")
        case .identityKeys:
            L10n.string("Public and private keys")
        case .relays:
            L10n.string("Relay lists")
        case .keyPackages:
            L10n.string("Invite packages")
        case .appearance:
            L10n.string("Theme")
        case .notifications:
            L10n.string("Local alerts")
        case .developerMode:
            L10n.string("Storage and diagnostics")
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "gearshape"
        case .accounts:
            "person.2"
        case .profile:
            "person.crop.circle"
        case .identityKeys:
            "key.viewfinder"
        case .relays:
            "antenna.radiowaves.left.and.right"
        case .keyPackages:
            "key"
        case .appearance:
            "circle.lefthalf.filled"
        case .notifications:
            "bell.badge"
        case .developerMode:
            "stethoscope"
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            L10n.string("System")
        case .light:
            L10n.string("Light")
        case .dark:
            L10n.string("Dark")
        }
    }
}

enum LocalNotificationAuthorizationStatus: String, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var label: String {
        switch self {
        case .notDetermined:
            L10n.string("Not requested")
        case .denied:
            L10n.string("Denied")
        case .authorized:
            L10n.string("Allowed")
        case .provisional:
            L10n.string("Allowed quietly")
        case .ephemeral:
            L10n.string("Allowed for now")
        }
    }

    var canPostNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        }
    }
}

struct NotificationSettingsSnapshot: Equatable {
    var localNotificationsEnabled: Bool
    var nativePushEnabled: Bool

    static let defaults = NotificationSettingsSnapshot(
        localNotificationsEnabled: false,
        nativePushEnabled: false
    )
}

enum RelaySettingsSection: String, CaseIterable, Identifiable {
    case nip65 = "NIP-65"
    case inbox = "Inbox"
    case keyPackage = "Key packages"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nip65:
            rawValue
        case .inbox:
            L10n.string("Inbox")
        case .keyPackage:
            L10n.string("Key Packages")
        }
    }

    var description: String {
        switch self {
        case .nip65:
            L10n.string("Profile relay list")
        case .inbox:
            L10n.string("Message delivery relays")
        case .keyPackage:
            L10n.string("Key package discovery relays")
        }
    }
}

struct ProfileDraft: Equatable {
    var name = ""
    var displayName = ""
    var about = ""
    var picture = ""
    var nip05 = ""
    var lud16 = ""
}

struct RelaySettingsSnapshot: Equatable {
    var nip65: [String]
    var inbox: [String]
    var keyPackage: [String]

    static let defaults = RelaySettingsSnapshot(
        nip65: MarmotClient.seedRelays,
        inbox: MarmotClient.seedRelays,
        keyPackage: MarmotClient.seedRelays
    )

    func relays(for section: RelaySettingsSection) -> [String] {
        switch section {
        case .nip65: nip65
        case .inbox: inbox
        case .keyPackage: keyPackage
        }
    }

    mutating func setRelays(_ relays: [String], for section: RelaySettingsSection) {
        switch section {
        case .nip65:
            nip65 = relays
        case .inbox:
            inbox = relays
        case .keyPackage:
            keyPackage = relays
        }
    }
}

struct KeyPackageItem: Identifiable, Equatable {
    let accountRef: String?
    let accountIdHex: String
    let keyPackageId: String
    let keyPackageRefHex: String
    let eventIdHex: String
    let publishedAt: Date?
    let keyPackageBytes: UInt64
    let sourceRelays: [String]
    let isLocal: Bool
    let isRelayDiscovered: Bool

    var id: String {
        if !eventIdHex.isEmpty { return eventIdHex }
        if !keyPackageRefHex.isEmpty { return keyPackageRefHex }
        return keyPackageId
    }

    var sourceLabel: String {
        switch (isLocal, isRelayDiscovered) {
        case (true, true):
            "Local + relay"
        case (true, false):
            "Local"
        case (false, true):
            "Relay"
        case (false, false):
            "Unknown"
        }
    }

    var publishedLabel: String {
        guard let publishedAt else { return "Unknown" }
        return publishedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

struct NewChatRecipient: Equatable {
    let sourceQuery: String
    let memberRef: String
    let accountIdHex: String
    let npub: String
    let displayName: String?
    let pictureURL: String?

    var title: String {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty
        else { return DisplayText.short(accountIdHex) }

        return displayName
    }

    var subtitle: String {
        npub.isEmpty ? DisplayText.short(accountIdHex, head: 12, tail: 10) : npub
    }

    func matches(query: String) -> Bool {
        sourceQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ChatFilter {
    static func filtered(_ chats: [ChatItem], query: String) -> [ChatItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return chats }
        return chats.filter { chat in
            [chat.title, chat.subtitle, chat.preview]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(needle)
        }
    }
}

enum DisplayText {
    static func short(_ value: String, head: Int = 8, tail: Int = 6) -> String {
        guard value.count > head + tail + 3 else { return value }
        return "\(value.prefix(head))...\(value.suffix(tail))"
    }

    static func initials(for value: String, fallback: String) -> String {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
        let parts = source
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        if !letters.isEmpty { return letters }
        return String(source.prefix(2)).uppercased()
    }

    static func relativeTimestamp(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func messageTimestamp(for date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension AccountItem {
    static let samples: [AccountItem] = [
        AccountItem(
            id: "account-jeff",
            accountRef: "jeff",
            displayName: "Jeff",
            accountIdHex: "93f7d85ef9279a03e21b7a0f0716db579d45bbab0a664707d0af6c2e2d25aa11",
            initials: "JG"
        ),
        AccountItem(
            id: "account-lab",
            accountRef: "lab",
            displayName: "Lab",
            accountIdHex: "f46f35698b7d724aa0d746c7f6ef463d979df5e45756b7519e87f98535a44c01",
            initials: "LB"
        ),
        AccountItem(
            id: "account-field",
            accountRef: "field",
            displayName: "Field",
            accountIdHex: "20b014f1701db12b8d4732ad506ce310419eb86539913b010fe09f114d9ae51f",
            initials: "FD"
        )
    ]
}

extension ChatItem {
    static let samples: [ChatItem] = [
        ChatItem(
            id: "chat-design",
            title: "Marmot Design",
            subtitle: "8 members",
            preview: "The desktop shell can own layout while Rust owns identity and transport.",
            updatedAt: Date().addingTimeInterval(-820),
            avatarSeed: "chat-design",
            pictureURL: nil,
            unreadCount: 3
        ),
        ChatItem(
            id: "chat-nvk",
            title: "NVK",
            subtitle: "Direct message",
            preview: "Let's keep the left rail fast for account switching.",
            updatedAt: Date().addingTimeInterval(-7_600),
            avatarSeed: "chat-nvk",
            pictureURL: nil,
            unreadCount: 0
        ),
        ChatItem(
            id: "chat-relays",
            title: "Relay Ops",
            subtitle: "5 members",
            preview: "nos.lol and relay.primal.net both caught up on the last run.",
            updatedAt: Date().addingTimeInterval(-90_000),
            avatarSeed: "chat-relays",
            pictureURL: nil,
            unreadCount: 1
        )
    ]
}

extension MessageItem {
    static let samples: [String: [MessageItem]] = [
        "chat-design": [
            MessageItem(
                id: "m1",
                senderName: "NVK",
                body: "We should keep accounts visible all the time. Switching identities is core, not a settings errand.",
                sentAt: Date().addingTimeInterval(-4_500),
                isOutgoing: false
            ),
            MessageItem(
                id: "m2",
                senderName: "Jeff",
                body: "Agree. Narrow account rail, wider chat drawer, detail area does the heavy lifting.",
                sentAt: Date().addingTimeInterval(-3_900),
                isOutgoing: true
            ),
            MessageItem(
                id: "m3",
                senderName: "Shaka",
                body: "I will wire the app frame around MarmotKit so real accounts and chats have a place to land.",
                sentAt: Date().addingTimeInterval(-800),
                isOutgoing: false
            )
        ],
        "chat-nvk": [
            MessageItem(
                id: "m4",
                senderName: "NVK",
                body: "Desktop should feel denser than mobile without turning into a spreadsheet.",
                sentAt: Date().addingTimeInterval(-7_600),
                isOutgoing: false
            )
        ],
        "chat-relays": [
            MessageItem(
                id: "m5",
                senderName: "Relay Ops",
                body: "Seed relays are still damus, nos.lol, and primal for the initial Marmot runtime.",
                sentAt: Date().addingTimeInterval(-90_000),
                isOutgoing: false
            )
        ]
    ]
}
