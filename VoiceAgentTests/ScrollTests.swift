import SwiftUI
import UIKit
import XCTest
@testable import VoiceAgent

/// The chat while answers are written: the end of the conversation must stay in view.
@MainActor
final class ScrollTests: XCTestCase {
    @Observable final class Feed {
        var items: [ChatItem] = []
    }

    private struct Host: View {
        let feed: Feed
        var body: some View { MessageList(items: feed.items) { EmptyView() } }
    }

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
    }

    private func show(_ feed: Feed) throws -> UIHostingController<Host> {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Host(feed: feed))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        return host
    }

    private func settle(_ seconds: Double = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func scrollView() throws -> UIScrollView {
        func all(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        return try XCTUnwrap(window.flatMap { all($0).first })
    }

    /// How far the end of the content is below the bottom of the view; 0 when the end is in view.
    private func hidden() throws -> CGFloat {
        let s = try scrollView()
        let visibleEnd = s.contentOffset.y + s.bounds.height - s.adjustedContentInset.bottom
        return max(0, s.contentSize.height - visibleEnd)
    }

    private let words = "Přehled jsem našel v paměti, tady v kostce. Celkem šest strojů na jedné soukromé síti, dva boxy na grafických kartách, dva malé počítače s kontejnery a agenty a k tomu stolní počítač a notebook. Chceš se podívat podrobněji na něco z toho?".split(separator: " ").map(String.init)

    /// Writes an answer a few words at a time, the way a model streams it.
    private func stream(into feed: Feed, kind: ChatItem.Kind = .assistant, repeats: Int = 2, check: (Int) throws -> Void) rethrows {
        feed.items.append(ChatItem(kind: kind, text: ""))
        let i = feed.items.count - 1
        var step = 0
        for _ in 0..<repeats {
            for word in words {
                feed.items[i].text += (feed.items[i].text.isEmpty ? "" : " ") + word
                settle(0.03)
                step += 1
                try check(step)
            }
        }
    }

    func testTheEndStaysInViewWhileAnswersAreWritten() throws {
        let feed = Feed()
        feed.items = (0..<6).map { ChatItem(kind: $0 % 2 == 0 ? .user : .assistant, text: words.joined(separator: " ")) }
        _ = try show(feed)
        settle(1)
        XCTAssertLessThan(try hidden(), 2, "starts at the end")

        var worst: CGFloat = 0
        for round in 0..<3 {
            feed.items.append(ChatItem(kind: .user, text: "Otázka \(round)"))
            settle(0.2)
            try stream(into: feed) { _ in worst = max(worst, try hidden()) }
            // A second answer straight after the first, like a subagent's result.
            try stream(into: feed, repeats: 1) { _ in worst = max(worst, try hidden()) }
            settle(0.5)
            XCTAssertLessThan(try hidden(), 2, "round \(round): the end must be in view once the answer is written")
        }
        print("SCROLL worst hidden while writing:", worst)
        XCTAssertLessThan(worst, 60, "while writing, at most the line being written may be below the view")
    }

    /// The keyboard goes away after sending: the view grows taller and must still show the end.
    func testTheEndStaysInViewWhenTheViewChangesHeight() throws {
        let feed = Feed()
        feed.items = (0..<6).map { ChatItem(kind: $0 % 2 == 0 ? .user : .assistant, text: words.joined(separator: " ")) }
        let host = try show(feed)
        settle(1)
        let full = host.view.frame
        host.additionalSafeAreaInsets.bottom = 300 // like the keyboard
        settle(0.5)
        XCTAssertLessThan(try hidden(), 2, "with the keyboard")
        feed.items.append(ChatItem(kind: .user, text: "Otázka"))
        settle(0.1)
        host.additionalSafeAreaInsets.bottom = 0
        settle(0.3)
        var worst: CGFloat = 0
        try stream(into: feed) { _ in worst = max(worst, try hidden()) }
        settle(0.5)
        XCTAssertEqual(host.view.frame, full)
        print("SCROLL worst hidden after the keyboard:", worst)
        XCTAssertLessThan(try hidden(), 2, "the end must be in view once the answer is written")
        XCTAssertLessThan(worst, 60)
    }
}
