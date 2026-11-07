import Contacts
import EventKit
import Foundation

/// The built-in server: tools that work with this device's own data. It behaves like any MCP server for the agent
/// and for profiles, and every tool is off until the user turns it on.
enum PhoneTools {
    /// Stands for the device in a profile's list of servers.
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
        var def: ToolDef { ToolDef(name: "device__\(name)", description: description, schema: schema) }
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }
    private static func text(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    private static let timeFormat = "ISO 8601 local time, for example 2026-11-02T14:30, or a date such as 2026-11-02"

    static let all: [Tool] = [
        Tool(name: "list_events", area: .calendar, title: "Read events",
             description: "Lists events in the device's calendar between two times, including birthdays from the contacts. With query it lists only the events whose title, place or notes contain that text, so a long period such as a whole year can be searched for a person or a subject.",
             schema: object(["start": text(timeFormat), "end": text("End of the period, same format, at most four years after start. Default: one day after start."), "query": text("Optional text to look for, for example a name.")], required: ["start"])),
        Tool(name: "create_event", area: .calendar, title: "Add events",
             description: "Adds an event to the device's default calendar.",
             schema: object(["title": text("Title of the event."), "start": text(timeFormat), "end": text("End, same format. Default: one hour after start."), "all_day": ["type": "boolean"], "location": text("Optional place."), "notes": text("Optional notes.")], required: ["title", "start"])),
        Tool(name: "list_reminders", area: .reminders, title: "Read reminders",
             description: "Lists reminders on the device that are not completed yet.",
             schema: object([:])),
        Tool(name: "create_reminder", area: .reminders, title: "Add reminders",
             description: "Adds a reminder to the device's default list.",
             schema: object(["title": text("What to be reminded of."), "due": text("Optional due time. " + timeFormat), "notes": text("Optional notes.")], required: ["title"])),
        Tool(name: "complete_reminder", area: .reminders, title: "Complete reminders",
             description: "Marks a reminder as completed.",
             schema: object(["id": text("The id from list_reminders.")], required: ["id"])),
        Tool(name: "search_contacts", area: .contacts, title: "Search contacts",
             description: "Finds people in the device's contacts by name, with everything the contact holds: phone numbers, e-mail and postal addresses, birthday and other dates, organization, job, relations, web pages and social profiles.",
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
        let query = args["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { query.isEmpty || contains(query, in: [$0.title, $0.location, $0.notes]) }
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
        guard let calendar = store.defaultCalendarForNewEvents else { throw AppError("This device has no default calendar.") }
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
        guard let list = store.defaultCalendarForNewReminders() else { throw AppError("This device has no default reminders list.") }
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
        let predicate = CNContact.predicateForContacts(matchingName: try required(args, "name"))
        let found = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: contactKeys)
        return ["contacts": .array(found.prefix(20).map(contactJSON))]
    }

    /// Everything a contact holds, except the note and the photo: reading the note needs an entitlement from Apple.
    static let contactKeys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] + [
        CNContactNicknameKey, CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey,
        CNContactBirthdayKey, CNContactDatesKey, CNContactRelationsKey, CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey,
    ].map { $0 as CNKeyDescriptor }

    /// Only the fields the contact has; a birthday without a year is written --MM-DD.
    static func contactJSON(_ c: CNContact) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName)]
        func put(_ key: String, _ value: String) {
            if !value.isEmpty { o[key] = .string(value) }
        }
        func put<V: NSCopying & NSSecureCoding>(_ key: String, _ items: [CNLabeledValue<V>], _ value: (V) -> String) {
            let list: [JSONValue] = items.compactMap { item in
                let v = value(item.value)
                guard !v.isEmpty else { return nil }
                guard let label = item.label.map(CNLabeledValue<V>.localizedString(forLabel:)), !label.isEmpty else { return .string(v) }
                return ["label": .string(label), "value": .string(v)]
            }
            if !list.isEmpty { o[key] = .array(list) }
        }
        if c.isKeyAvailable(CNContactNicknameKey) { put("nickname", c.nickname) }
        put("organization", c.organizationName)
        if c.isKeyAvailable(CNContactDepartmentNameKey) { put("department", c.departmentName) }
        if c.isKeyAvailable(CNContactJobTitleKey) { put("job_title", c.jobTitle) }
        put("phones", c.phoneNumbers) { $0.stringValue }
        put("emails", c.emailAddresses) { $0 as String }
        if c.isKeyAvailable(CNContactPostalAddressesKey) {
            put("addresses", c.postalAddresses) { CNPostalAddressFormatter.string(from: $0, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ") }
        }
        if c.isKeyAvailable(CNContactUrlAddressesKey) { put("web", c.urlAddresses) { $0 as String } }
        if c.isKeyAvailable(CNContactBirthdayKey), let b = c.birthday { put("birthday", day(b)) }
        if c.isKeyAvailable(CNContactDatesKey) { put("dates", c.dates) { day($0 as DateComponents) } }
        if c.isKeyAvailable(CNContactRelationsKey) { put("relations", c.contactRelations) { $0.name } }
        if c.isKeyAvailable(CNContactSocialProfilesKey) {
            put("social_profiles", c.socialProfiles) { p in [p.service, p.username.isEmpty ? p.urlString : p.username].filter { !$0.isEmpty }.joined(separator: ": ") }
        }
        if c.isKeyAvailable(CNContactInstantMessageAddressesKey) {
            put("messaging", c.instantMessageAddresses) { m in [m.service, m.username].filter { !$0.isEmpty }.joined(separator: ": ") }
        }
        return .object(o)
    }

    /// yyyy-MM-dd, or --MM-dd when the year is not known.
    static func day(_ d: DateComponents) -> String {
        guard let month = d.month, let day = d.day, month != NSDateComponentUndefined, day != NSDateComponentUndefined else { return "" }
        let md = String(format: "%02d-%02d", month, day)
        if let year = d.year, year != NSDateComponentUndefined { return String(format: "%04d-", year) + md }
        return "--" + md
    }

    /// Whether any of the texts contains the query, ignoring case and accents.
    static func contains(_ query: String, in texts: [String?]) -> Bool {
        texts.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
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
