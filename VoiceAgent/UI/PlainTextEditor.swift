import SwiftUI
import UIKit

/// Multi-line text box. SwiftUI's TextEditor moves the cursor to the end after a paste, which makes the
/// middle of a long text impossible to edit; this one sets the text only when it really differs.
struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// For JSON and similar: no capitals, corrections or curly quotes.
    var literal = false
    /// When set, the box grows with its text between these line counts and then scrolls.
    var lines: ClosedRange<Int>?
    /// When set, Return on a hardware keyboard (a Mac, an iPad keyboard) calls this and Shift-Return starts a new line.
    /// The on-screen keyboard has no Shift-Return, so its Return key still starts a new line.
    var onSubmit: (() -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let view = SubmittingTextView()
        view.onSubmit = onSubmit
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.font = literal
            ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
            : .preferredFont(forTextStyle: .body)
        if literal {
            view.autocapitalizationType = .none
            view.autocorrectionType = .no
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
        }
        view.text = text
        if lines != nil {
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let lines, let font = view.font, let width = proposal.width else { return nil }
        let content = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(content, font.lineHeight * CGFloat(lines.lowerBound)), font.lineHeight * CGFloat(lines.upperBound))
        return CGSize(width: width, height: ceil(height))
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        (view as? SubmittingTextView)?.onSubmit = onSubmit
        if view.text == text {
            coordinator.sent.removeAll()
            return
        }
        // While typing fast this can run with a value the box itself sent a moment ago; putting it back would undo the typing.
        if let echo = coordinator.sent.firstIndex(of: text) {
            coordinator.sent.removeFirst(echo + 1)
            return
        }
        coordinator.sent.removeAll()
        let selection = view.selectedRange
        view.text = text
        let length = (text as NSString).length
        view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlainTextEditor
        var sent: [String] = []
        init(parent: PlainTextEditor) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            sent.append(view.text)
            parent.text = view.text
        }
    }
}

/// Return sends and Shift-Return starts a new line, for hardware keyboards only: key commands never fire for the
/// on-screen keyboard.
final class SubmittingTextView: UITextView {
    var onSubmit: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        guard onSubmit != nil else { return super.keyCommands }
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(submit))
        let newLine = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertNewLine))
        for command in [send, newLine] { command.wantsPriorityOverSystemBehavior = true }
        return [send, newLine] + (super.keyCommands ?? [])
    }

    @objc private func submit() {
        // Return that finishes a word being composed (accents, other scripts) only finishes it.
        if markedTextRange != nil { unmarkText(); return }
        onSubmit?()
    }

    @objc private func insertNewLine() { insertText("\n") }
}

/// A box that grows with its text, with a placeholder, in place of `TextField(axis: .vertical)`, which loses the cursor the same way.
struct MultilineField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...4
    var literal = false
    var onSubmit: (() -> Void)?

    var body: some View {
        PlainTextEditor(text: $text, literal: literal, lines: lines, onSubmit: onSubmit)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(title)
                        .font(literal ? .system(.footnote, design: .monospaced) : .body)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Phone keyboards have no key that puts them away: a tap into the content (not a text box) does, on every screen
/// and sheet of the window. The tap still reaches what was tapped.
struct KeyboardDismissal: UIViewRepresentable {
    /// Only a tap into the content: the chat or a settings list. The buttons beside the message box (send, stop)
    /// leave the keyboard up, so the next message can be typed straight away.
    static func dismisses(tapOn view: UIView?) -> Bool {
        var view = view
        while let v = view {
            if v is UITextField || v is UITextView { return false }
            if v is UIScrollView { return true }
            view = v.superview
        }
        return false
    }

    func makeUIView(context: Context) -> Installer { Installer() }
    func updateUIView(_ view: Installer, context: Context) {}

    final class Installer: UIView, UIGestureRecognizerDelegate {
        private weak var installedOn: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, window !== installedOn else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            installedOn = window
        }

        @objc private func tapped() { installedOn?.endEditing(true) }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            KeyboardDismissal.dismisses(tapOn: touch.view)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
