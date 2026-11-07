import SwiftUI
import UIKit
import XCTest
@testable import VoiceAgent

/// Types into the real settings screens through the keyboard input path, the way a finger does.
@MainActor
final class TextFieldTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
    }

    private func show<V: View>(_ view: V) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
    }

    private func settle(_ seconds: Double = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func textFields() -> [UITextField] {
        func all(_ view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(all)
        }
        guard let window else { return [] }
        return all(window).sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }

    private func type(_ text: String, into index: Int) throws -> UITextField {
        var field = try XCTUnwrap(textFields()[safe: index], "no text field \(index)")
        XCTAssertTrue(field.becomeFirstResponder())
        settle()
        for ch in text {
            if !field.isFirstResponder, let again = textFields()[safe: index] { field = again }
            XCTAssertTrue(field.isFirstResponder, "the field lost the keyboard before \(ch)")
            field.insertText(String(ch))
            settle(0.15)
        }
        return field
    }

    private func store() -> SettingsStore {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "text-\(UUID())")!)
        store.settings.servers = [LLMServer(name: "", api: LLMAPI.allCases[0], baseURL: "")]
        return store
    }

    func testServerNameKeepsWhatWasTyped() throws {
        let store = store()
        try show(ServerHost(store: store))
        settle(1)
        let field = try type("Abc", into: 0)
        XCTAssertEqual(store.settings.servers[0].name, "Abc")
        field.resignFirstResponder()
        settle()
        XCTAssertEqual(store.settings.servers[0].name, "Abc", "leaving the field must keep the text")
        XCTAssertEqual(textFields().first?.text, "Abc")
    }

    /// A hardware keyboard: Return sends, Shift-Return starts a new line. Without a send action Return stays a new line.
    func testReturnSendsAndShiftReturnStartsALine() throws {
        var sent = 0
        let view = SubmittingTextView()
        view.onSubmit = { sent += 1 }
        view.text = "Hi"
        let commands = try XCTUnwrap(view.keyCommands).filter { $0.input == "\r" }
        let send = try XCTUnwrap(commands.first { $0.modifierFlags.isEmpty })
        let newLine = try XCTUnwrap(commands.first { $0.modifierFlags == .shift })
        XCTAssertTrue(send.wantsPriorityOverSystemBehavior)
        view.selectedRange = NSRange(location: 2, length: 0)
        view.perform(newLine.action)
        XCTAssertEqual(view.text, "Hi\n")
        XCTAssertEqual(sent, 0)
        view.perform(send.action)
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(view.text, "Hi\n", "sending adds no line")
        XCTAssertNil(SubmittingTextView().keyCommands?.first { $0.input == "\r" })
    }

    /// Tapping send keeps the keyboard up for the next message; tapping into the chat puts it away.
    func testOnlyATapIntoTheContentPutsTheKeyboardAway() {
        let bar = UIView()
        let button = UIView()
        bar.addSubview(button)
        XCTAssertFalse(KeyboardDismissal.dismisses(tapOn: button), "a button beside the message box")

        let chat = UIScrollView()
        let bubble = UIView()
        chat.addSubview(bubble)
        XCTAssertTrue(KeyboardDismissal.dismisses(tapOn: bubble), "a bubble in the chat")

        let field = UITextView()
        chat.addSubview(field)
        XCTAssertFalse(KeyboardDismissal.dismisses(tapOn: field), "the text box itself")
        XCTAssertFalse(KeyboardDismissal.dismisses(tapOn: nil))
    }
}

extension TextFieldTests {
    private func collectionViews() -> [UICollectionView] {
        func all(_ view: UIView) -> [UICollectionView] {
            ((view as? UICollectionView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        var views: [UIView] = window.map { [$0] } ?? []
        var presented = window?.rootViewController?.presentedViewController
        while let vc = presented { views.append(vc.view); presented = vc.presentedViewController }
        return views.flatMap(all).filter { $0.window != nil && !$0.isHidden }
    }

    /// Opens a row the way a tap does, in the list that is on screen now.
    private func open(section: Int, item: Int) throws {
        let list = try XCTUnwrap(collectionViews().last, "no list on screen")
        let path = IndexPath(item: item, section: section)
        list.delegate?.collectionView?(list, didSelectItemAt: path)
        settle(1)
    }

    private func allTextFields() -> [UITextField] {
        func all(_ view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(all)
        }
        var views: [UIView] = window.map { [$0] } ?? []
        var presented = window?.rootViewController?.presentedViewController
        while let vc = presented { views.append(vc.view); presented = vc.presentedViewController }
        var seen = Set<ObjectIdentifier>()
        return views.flatMap(all).filter { $0.window != nil && seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// The same path as in the app: chat screen, Settings sheet, LLM servers, a server.
    func testServerNameKeepsWhatWasTypedInsideSettings() throws {
        let store = store()
        store.settings.dataNoticeAccepted = true
        try show(SheetHost(store: store))
        settle(1.5)
        try open(section: 1, item: 0)
        try open(section: 0, item: 0)
        var field = try XCTUnwrap(allTextFields().min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }, "no field in the server editor")
        XCTAssertTrue(field.becomeFirstResponder())
        settle()
        for ch in "Abc" {
            if !field.isFirstResponder, let again = allTextFields().first { field = again }
            XCTAssertTrue(field.isFirstResponder, "the field lost the keyboard before \(ch)")
            field.insertText(String(ch))
            settle(0.15)
        }
        XCTAssertEqual(store.settings.servers[0].name, "Abc")
        field.resignFirstResponder()
        settle()
        XCTAssertEqual(store.settings.servers[0].name, "Abc", "leaving the field must keep the text")
    }
}

extension TextFieldTests {
    /// The keyboard keeps the word being typed as marked text (suggestions, corrections) and commits it later.
    func testMarkedTextIsKept() throws {
        let store = store()
        store.settings.dataNoticeAccepted = true
        try show(SheetHost(store: store))
        settle(1.5)
        try open(section: 1, item: 0)
        try open(section: 0, item: 0)
        var field = try XCTUnwrap(allTextFields().min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY })
        XCTAssertTrue(field.becomeFirstResponder())
        settle()
        for word in ["A", "Ab", "Abc"] {
            if !field.isFirstResponder, let again = allTextFields().first { field = again }
            field.setMarkedText(word, selectedRange: NSRange(location: word.count, length: 0))
            settle(0.2)
            print("MARKED after \(word): field=\(field.text ?? "nil") store=\(store.settings.servers[0].name) responder=\(field.isFirstResponder)")
        }
        field.unmarkText()
        settle()
        print("MARKED after commit: field=\(field.text ?? "nil") store=\(store.settings.servers[0].name)")
        XCTAssertEqual(store.settings.servers[0].name, "Abc")
        field.resignFirstResponder()
        settle()
        XCTAssertEqual(store.settings.servers[0].name, "Abc", "leaving the field must keep the text")
    }
}

extension TextFieldTests {
    private func fieldsTopDown() -> [UITextField] {
        allTextFields().sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }

    private func typeKeys(_ text: String, at index: Int) throws {
        let field = try XCTUnwrap(fieldsTopDown()[safe: index], "no field \(index)")
        XCTAssertTrue(field.becomeFirstResponder(), "field \(index) did not take the keyboard")
        settle()
        for ch in text {
            let now = fieldsTopDown()[safe: index] ?? field
            now.insertText(String(ch))
            settle(0.15)
        }
    }

    /// The user's steps: type the name, tap the URL field, type it, tap the next field.
    func testMovingToTheNextFieldKeepsTheText() throws {
        let store = store()
        store.settings.dataNoticeAccepted = true
        try show(SheetHost(store: store))
        settle(1.5)
        try open(section: 1, item: 0)
        try open(section: 0, item: 0)
        try typeKeys("Abc", at: 0)
        try typeKeys("http://x", at: 1)
        print("STEPS after URL: store name=\(store.settings.servers[0].name) url=\(store.settings.servers[0].baseURL) fields=\(fieldsTopDown().map { $0.text ?? "" })")
        XCTAssertEqual(store.settings.servers[0].name, "Abc", "the name must survive tapping the URL field")
        let key = try XCTUnwrap(fieldsTopDown()[safe: 2])
        XCTAssertTrue(key.becomeFirstResponder())
        settle()
        print("STEPS after key: store name=\(store.settings.servers[0].name) url=\(store.settings.servers[0].baseURL) fields=\(fieldsTopDown().map { $0.text ?? "" })")
        XCTAssertEqual(store.settings.servers[0].name, "Abc")
        XCTAssertEqual(store.settings.servers[0].baseURL, "http://x")
    }
}

extension TextFieldTests {
    /// The bug users met: a screen pushed with navigationDestination is not redrawn with its list. It must still
    /// show what is in the store, or moving to the next field puts an old copy back.
    func testEditorFollowsTheStoreWithoutItsList() throws {
        let store = store()
        try show(StaticHost(store: store, id: store.settings.servers[0].id))
        settle(1)
        try typeKeys("Abc", at: 0)
        try typeKeys("http://x", at: 1)
        XCTAssertEqual(fieldsTopDown().first?.text, "Abc", "the name must stay after moving to the URL field")
        XCTAssertEqual(store.settings.servers[0].name, "Abc")
        XCTAssertEqual(store.settings.servers[0].baseURL, "http://x")
        store.settings.servers[0].name = "Changed"
        settle()
        XCTAssertEqual(fieldsTopDown().first?.text, "Changed", "a change made elsewhere must show")
    }

    func testSoulKeepsWhatWasTyped() throws {
        let store = store()
        store.settings.profiles = [AgentProfile()]
        try show(SoulHost(store: store, id: store.settings.profiles[0].id))
        settle(1)
        func views(_ v: UIView) -> [UITextView] { ((v as? UITextView).map { [$0] } ?? []) + v.subviews.flatMap(views) }
        let box = try XCTUnwrap(window.flatMap { views($0).first })
        XCTAssertTrue(box.becomeFirstResponder())
        settle()
        for ch in "Ahoj" { box.insertText(String(ch)); settle(0.15) }
        XCTAssertEqual(store.settings.profiles[0].soul.text, "Ahoj")
        store.settings.servers[0].name = "something else changes"
        settle()
        XCTAssertEqual(box.text, "Ahoj", "the soul must not be wiped")
        box.resignFirstResponder()
        settle()
        XCTAssertEqual(store.settings.profiles[0].soul.text, "Ahoj")
    }
}

/// Does not read the store, so it never redraws what it pushed, like a navigationDestination.
private struct StaticHost: View {
    let store: SettingsStore
    let id: UUID
    var body: some View {
        NavigationStack { Live(store: store, list: \.servers, id: id) { LLMServerEditor(store: store, server: $0) } }
    }
}

private struct SoulHost: View {
    let store: SettingsStore
    let id: UUID
    var body: some View {
        NavigationStack { Live(store: store, list: \.profiles, id: id) { SoulView(soul: $0.soul, conversation: AppModel.conversation) } }
    }
}

/// Like ChatView: reads the settings, so every change redraws it, and shows Settings in a sheet.
private struct SheetHost: View {
    @Bindable var store: SettingsStore
    var body: some View {
        NavigationStack {
            Text(verbatim: store.settings.profile.displayName)
        }
        .environment(\.locale, Locale(identifier: Localizer.code))
        .sheet(isPresented: .constant(true)) {
            SettingsView(store: store, conversation: AppModel.conversation)
        }
    }
}

private struct ServerHost: View {
    @Bindable var store: SettingsStore
    var body: some View {
        NavigationStack { LLMServerEditor(store: store, server: $store.settings.servers[0]) }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
