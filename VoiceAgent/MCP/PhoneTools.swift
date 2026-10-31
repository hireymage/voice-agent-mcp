import Contacts
import EventKit
import Foundation

/// The built-in server: tools that work with this iPhone's own data. It behaves like any MCP server for the agent
/// and for profiles, and every tool is off until the user turns it on.
enum PhoneTools {
    /// Stands for the iPhone in a profile's list of servers.
    static let serverID = UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!

    enum Area: String, CaseIterable, Identifiable {
        case calendar, reminders, contacts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .calendar: tr("Calendar")
            case .reminders: tr("Reminders")
            case .contacts: tr("Contacts")
            }
        }
    }

    struct Tool: Identifiable {
        let name: String, area: Area, title: String, description: String, schema: JSONValue
        var id: String { name }
        var def: ToolDef { ToolDef(name: "iphone__\(name)", description: description, schema: schema) }
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }
    private static func text(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    private static let timeFormat = "ISO 8601 local time, for example 2026-11-02T14:30, or a date such as 2026-11-02"

    static let all: [Tool] = [
        Tool(name: "list_events", area: .calendar, title: "Read events",
             description: "Lists events in the iPhone calendar between two times.",
             schema: object(["start": text(timeFormat), "end": text("End of the period, same format. Default: one day after start.")], required: ["start"])),
        Tool(name: "create_event", area: .calendar, title: "Add events",
             description: "Adds an event to the default iPhone calendar.",
             schema: object(["title": text("Title of the event."), "start": text(timeFormat), "end": text("End, same format. Default: one hour after start."), "all_day": ["type": "boolean"], "location": text("Optional place."), "notes": text("Optional notes.")], required: ["title", "start"])),
        Tool(name: "list_reminders", area: .reminders, title: "Read reminders",
             description: "Lists reminders on the iPhone that are not completed yet.",
             schema: object([:])),
        Tool(name: "create_reminder", area: .reminders, title: "Add reminders",
             description: "Adds a reminder to the default iPhone list.",
             schema: object(["title": text("What to be reminded of."), "due": text("Optional due time. " + timeFormat), "notes": text("Optional notes.")], required: ["title"])),
        Tool(name: "complete_reminder", area: .reminders, title: "Complete reminders",
             description: "Marks a reminder as completed.",
             schema: object(["id": text("The id from list_reminders.")], required: ["id"])),
        Tool(name: "search_contacts", area: .contacts, title: "Search contacts",
             description: "Finds people in the iPhone contacts by name, with their phone numbers and e-mail addresses.",
             schema: object(["name": text("A name or part of it.")], required: ["name"])),
    ]

    /// Tools that only read, the ones that may run while the user is still talking.
    static func readsOnly(_ name: String) -> Bool { name.hasPrefix("list_") || name.hasPrefix("search_") }

    /// What the agent gets for the tools the user has turned on.
    static func agentTools(enabled: [String]) -> [AgentTool] {
        all.filter { enabled.contains($0.name) }.map { tool in
            AgentTool(def: tool.def) { arguments in
                guard let args = JSONValue.parse(arguments.isEmpty ? "{}" : arguments), args.object != nil else {
                    return ("Tool arguments were not a JSON object.", true)
                }
                do {
                    return (try await run(tool.name, args).compact, false)
                } catch {
                    return (error.localizedDescription, true)
                }
            }
        }
    }

    // MARK: - Permission

    static func requestAccess(_ area: Area) async -> Bool {
        switch area {
        case .calendar: (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        case .reminders: (try? await EKEventStore().requestFullAccessToReminders()) ?? false
        case .contacts: (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        }
    }

    private static func requireAccess(_ area: Area) async throws {
        guard await requestAccess(area) else {
            throw AppError("Access is off. Turn it on in iOS Settings.")
        }
    }

    // MARK: - Tools

    static func run(_ name: String, _ args: JSONValue) async throws -> JSONValue {
        switch name {
        case "list_events": return try await listEvents(args)
        case "create_event": return try await createEvent(args)
        case "list_reminders": return try await listReminders()
        case "create_reminder": return try await createReminder(args)
        case "complete_reminder": return try await completeReminder(args)
        case "search_contacts": return try await searchContacts(args)
        default: throw AppError(tr("Unknown tool: %@", name))
        }
    }

    private static func required(_ args: JSONValue, _ key: String) throws -> String {
        guard let v = args[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            throw ToolInput("Missing \(key).")
        }
        return v
    }

    private static func requiredDate(_ args: JSONValue, _ key: String) throws -> Date {
        let value = try required(args, key)
        guard let date = parseDate(value) else { throw ToolInput("Cannot read the time in \(key): \(value)") }
        return date
    }

    private static func optionalDate(_ args: JSONValue, _ key: String) throws -> Date? {
        guard args[key]?.string?.isEmpty == false else { return nil }
        return try requiredDate(args, key)
    }

    private static func listEvents(_ args: JSONValue) async throws -> JSONValue {
        try await requireAccess(.calendar)
        let start = try requiredDate(args, "start")
        let end = try optionalDate(args, "end") ?? start.addingTimeInterval(86400)
        guard end > start else { throw ToolInput("The end must be after the start.") }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        return ["events": .array(events.prefix(100).map { e in
            var o: [String: JSONValue] = ["title": .string(e.title ?? ""), "start": .string(format(e.startDate)), "end": .string(format(e.endDate)), "all_day": .bool(e.isAllDay), "calendar": .string(e.calendar?.title ?? "")]
            if let l = e.location, !l.isEmpty { o["location"] = .string(l) }
            if let n = e.notes, !n.isEmpty { o["notes"] = .string(n) }
            return .object(o)
        })]
    }

    private static func createEvent(_ args: JSONValue) async throws -> JSONValue {
        try await requireAccess(.calendar)
        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents else { throw AppError("This iPhone has no default calendar.") }
        let e = EKEvent(eventStore: store)
        e.calendar = calendar
        e.title = try required(args, "title")
        e.startDate = try requiredDate(args, "start")
        e.endDate = try optionalDate(args, "end") ?? e.startDate.addingTimeInterval(3600)
        if case .bool(true)? = args["all_day"] { e.isAllDay = true }
        e.location = args["location"]?.string
        e.notes = args["notes"]?.string
        try store.save(e, span: .thisEvent, commit: true)
        return ["created": .string(e.title ?? ""), "start": .string(format(e.startDate)), "end": .string(format(e.endDate)), "calendar": .string(calendar.title)]
    }

    private static func listReminders() async throws -> JSONValue {
        try await requireAccess(.reminders)
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let list: [JSONValue] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { reminders in
                c.resume(returning: (reminders ?? []).prefix(100).map { r in
                    var o: [String: JSONValue] = ["id": .string(r.calendarItemIdentifier), "title": .string(r.title ?? ""), "list": .string(r.calendar?.title ?? "")]
                    if let due = r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) { o["due"] = .string(format(due)) }
                    if let n = r.notes, !n.isEmpty { o["notes"] = .string(n) }
                    return .object(o)
                })
            }
        }
        return ["reminders": .array(list)]
    }

    private static func createReminder(_ args: JSONValue) async throws -> JSONValue {
        try await requireAccess(.reminders)
        let store = EKEventStore()
        guard let list = store.defaultCalendarForNewReminders() else { throw AppError("This iPhone has no default reminders list.") }
        let r = EKReminder(eventStore: store)
        r.calendar = list
        r.title = try required(args, "title")
        r.notes = args["notes"]?.string
        if let due = try optionalDate(args, "due") {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        try store.save(r, commit: true)
        return ["created": .string(r.title ?? ""), "id": .string(r.calendarItemIdentifier), "list": .string(list.title)]
    }

    private static func completeReminder(_ args: JSONValue) async throws -> JSONValue {
        try await requireAccess(.reminders)
        let id = try required(args, "id")
        let store = EKEventStore()
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolInput("No reminder with this id.") }
        r.isCompleted = true
        try store.save(r, commit: true)
        return ["completed": .string(r.title ?? "")]
    }

    private static func searchContacts(_ args: JSONValue) async throws -> JSONValue {
        try await requireAccess(.contacts)
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: try required(args, "name"))
        let found = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
        let list: [JSONValue] = found.prefix(20).map { c in
            let phones: [JSONValue] = c.phoneNumbers.map { .string($0.value.stringValue) }
            let emails: [JSONValue] = c.emailAddresses.map { .string($0.value as String) }
            let o: [String: JSONValue] = [
                "name": .string(CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName),
                "organization": .string(c.organizationName),
                "phones": .array(phones),
                "emails": .array(emails),
            ]
            return .object(o)
        }
        return ["contacts": .array(list)]
    }

    // MARK: - Times

    /// Models write times in several forms; a time without a zone means the phone's own zone.
    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ssxxx", "yyyy-MM-dd'T'HH:mmxxx", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = pattern
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
        return f.string(from: date)
    }
}

/// A mistake in what the model asked for; it reads this and corrects itself, so it stays in English.
private struct ToolInput: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
