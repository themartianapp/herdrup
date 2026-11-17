import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void
    var isPresented = true
    var placeholder = "Type a reply…"
    var accessibilityIdentifier = "terminal-reply-input"
    var capitalization: UITextAutocapitalizationType = .none
    var autocorrection: UITextAutocorrectionType = .no
    var onChange: (String, String) -> Void = { _, _ in }
    var onReturn: ((String) -> Void)?
    var onCommandReturn: (() -> Void)?
    var onPasteFile: ((NSItemProvider) -> Bool)?
    /// The pull-to-expand editor's height; nil lets the field size itself to its text,
    /// up to `ComposerStyle.visibleLines`.
    var fixedHeight: CGFloat?
    /// UTF-16 ranges of `text` drawn in `Palette.brand` (Gram's addressing @mention). Empty
    /// (the terminal) never touches the text storage.
    var accentRanges: [NSRange] = []
    /// The caret (the end of the selection) as a UTF-16 offset into the field's text, with
    /// that text's UTF-16 length, whenever the reader moves it or types; an unchanged pair is
    /// reported once. Nil (the terminal) reports nothing. Setting it also keeps the caret's
    /// distance from the end of the text when the host replaces the text (Gram's @
    /// completion), instead of only following the end.
    var onSelectionChange: ((_ offset: Int, _ textLength: Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReplyTextView {
        let view = ReplyTextView()
        view.onPasteFile = onPasteFile
        view.onCommandReturn = onCommandReturn
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(Palette.text)
        view.tintColor = UIColor(Palette.text)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.configureTypography()
        view.autocapitalizationType = capitalization
        view.autocorrectionType = autocorrection
        view.returnKeyType = onReturn == nil ? .default : .send
        // Scrolling is ON at every height (see `refreshScrollMode`); only bouncing tracks
        // whether the content overflows.
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.updatePlaceholder()
        return view
    }

    func updateUIView(_ view: ReplyTextView, context: Context) {
        context.coordinator.parent = self
        // Selection changes made from here are this update's own, not the reader's.
        view.isApplyingUpdate = true
        defer { view.isApplyingUpdate = false }
        // SwiftUI opacity does not hide the retained UITextView from UIKit/AX.
        // Keep the native editor mounted, but make its visibility match its pane.
        view.isHidden = !isPresented
        // Neither that nor the pane's `accessibilityHidden` takes it out of the tree XCUITest
        // reads: a warm pane's hidden editor answered to the front one's identifier, the two
        // were told apart only by their order, and a composer animation flipped it (#677).
        // So only the presented editor is the reply input.
        view.accessibilityIdentifier = isPresented ? accessibilityIdentifier : nil
        if !isPresented { context.coordinator.nativeFocusPendingStateSync = false }
        view.onPasteFile = onPasteFile
        view.onCommandReturn = onCommandReturn
        view.configureTypography()
        view.setPlaceholder(placeholder)
        if view.text != text {
            context.coordinator.scheduleTextUpdate(in: view)
        }
        view.applyAccents(accentRanges)
        if view.fixedHeight != fixedHeight {
            view.fixedHeight = fixedHeight
            view.invalidateIntrinsicContentSize()
            view.refreshScrollMode()
        }
        view.isEditable = isEnabled
        if isFocused && isPresented {
            context.coordinator.nativeFocusPendingStateSync = false
            if !view.isFirstResponder {
                view.becomeFirstResponder()
            }
        } else if view.isFirstResponder, !context.coordinator.nativeFocusPendingStateSync {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReplyTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let natural = uiView.fittingHeight(for: width)
        return CGSize(
            width: width,
            height: min(max(natural, uiView.minimumHeight), uiView.maximumHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextField
        /// A native tap reaches UIKit before SwiftUI commits the FocusState update.
        /// Keep that responder alive through text-binding renders until the true state arrives.
        var nativeFocusPendingStateSync = false

        private var textUpdateScheduled = false
        init(_ parent: ComposerTextField) {
            self.parent = parent
        }

        /// A layout pass can carry a binding snapshot from before the latest native edit.
        /// Read the live binding off that pass instead of replacing newer UIKit text with it.
        func scheduleTextUpdate(in view: ReplyTextView) {
            guard !textUpdateScheduled else { return }
            textUpdateScheduled = true
            Task { @MainActor [weak self, weak view] in
                guard let self else { return }
                self.textUpdateScheduled = false
                guard let view else { return }
                let text = self.parent.text
                guard view.text != text else { return }
                view.isApplyingUpdate = true
                defer { view.isApplyingUpdate = false }
                // Dictation and restored drafts follow the end; an edit elsewhere keeps
                // its offset from the end, as it did before deferring synchronization.
                let oldLength = (view.text as NSString).length
                let caretFromEnd = oldLength - NSMaxRange(view.selectedRange)
                let followsEnd = view.selectedRange.location >= oldLength
                view.attributedText = NSAttributedString(string: text, attributes: view.composerAttributes)
                view.typingAttributes = view.composerAttributes
                view.accentsReset()
                self.reportedCaret = nil
                view.updatePlaceholder()
                view.invalidateIntrinsicContentSize()
                view.refreshScrollMode()
                if followsEnd {
                    view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                    view.requestCaretReveal()
                } else if self.parent.onSelectionChange != nil {
                    let length = (text as NSString).length
                    view.selectedRange = NSRange(location: min(length, max(0, length - caretFromEnd)), length: 0)
                    view.requestCaretReveal()
                }
                view.applyAccents(self.parent.accentRanges)
            }
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            nativeFocusPendingStateSync = true
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            nativeFocusPendingStateSync = false
            // `resignFirstResponder()` and `isEditable = false` both run from INSIDE
            // updateUIView and both end editing synchronously, so writing the focus binding
            // straight through from here mutates SwiftUI state during its own update pass
            // ("Modifying state during view update, this will cause undefined behavior").
            // Hop off the pass, and skip the write when the declared state already agrees —
            // @State has no same-value short circuit, so an equal write still publishes.
            guard parent.isFocused else { return }
            let notify = parent.onFocusChange
            Task { @MainActor in notify(false) }
        }

        func textViewDidChange(_ textView: UITextView) {
            let old = parent.text
            let new = textView.text ?? ""
            parent.text = new
            parent.onChange(old, new)
            (textView as? ReplyTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
            (textView as? ReplyTextView)?.refreshScrollMode()
            (textView as? ReplyTextView)?.requestCaretReveal()
            reportSelection(of: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            reportSelection(of: textView)
        }

        /// The last caret offset and text length reported, so an unchanged pair is not
        /// reported again. Forgotten when the host replaces the text: the host then holds its
        /// own idea of the caret, and the reader's next move must reach it even if equal.
        var reportedCaret: (offset: Int, length: Int)?

        private func reportSelection(of textView: UITextView) {
            guard let onSelectionChange = parent.onSelectionChange,
                  (textView as? ReplyTextView)?.isApplyingUpdate != true else { return }
            let caret = NSMaxRange(textView.selectedRange)
            let length = ((textView.text ?? "") as NSString).length
            guard reportedCaret?.offset != caret || reportedCaret?.length != length else { return }
            reportedCaret = (caret, length)
            onSelectionChange(caret, length)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n", let onReturn = parent.onReturn else { return true }
            onReturn(textView.text ?? "")
            return false
        }
    }

    final class ReplyTextView: UITextView {
        var onPasteFile: ((NSItemProvider) -> Bool)?
        var onCommandReturn: (() -> Void)?
        private lazy var sendKeyCommand: UIKeyCommand = {
            let command = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturn))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }()

        override var keyCommands: [UIKeyCommand]? {
            guard onCommandReturn != nil else { return super.keyCommands }
            return (super.keyCommands ?? []) + [sendKeyCommand]
        }

        @objc private func commandReturn() { onCommandReturn?() }
        private let placeholder = UILabel()
        private(set) var lineHeight: CGFloat = 24
        var fixedHeight: CGFloat?
        var minimumHeight: CGFloat { fixedHeight ?? lineHeight }
        var maximumHeight: CGFloat { fixedHeight ?? lineHeight * CGFloat(ComposerStyle.visibleLines) }
        private(set) var composerAttributes: [NSAttributedString.Key: Any] = [:]
        /// True while `updateUIView` runs: selection changes then are the host's own.
        var isApplyingUpdate = false
        /// The accent ranges last drawn and the text they were drawn on (see `applyAccents`).
        private var appliedAccents: [NSRange] = []
        private var accentedText = ""

        /// The text was replaced with plain attributes: nothing is drawn in the accent now.
        func accentsReset() {
            appliedAccents = []
            accentedText = ""
        }

        /// Draws `ranges` in `Palette.brand` and the rest in the text colour, in place in the
        /// text storage, so the selection, the undo stack and the scroll position stay. Redrawn
        /// only when the ranges change, or the text changed under drawn ranges (a character
        /// typed right after a mention takes its colour from it). Skipped during IME
        /// composition. With no ranges drawn or asked for, the storage is never touched.
        func applyAccents(_ ranges: [NSRange]) {
            guard markedTextRange == nil else { return }
            let current = text ?? ""
            guard ranges != appliedAccents || (!ranges.isEmpty && current != accentedText) else { return }
            let length = (current as NSString).length
            textStorage.beginEditing()
            textStorage.addAttribute(.foregroundColor, value: UIColor(Palette.text),
                                     range: NSRange(location: 0, length: length))
            for range in ranges where NSMaxRange(range) <= length {
                textStorage.addAttribute(.foregroundColor, value: UIColor(Palette.brand), range: range)
            }
            textStorage.endEditing()
            typingAttributes = composerAttributes
            appliedAccents = ranges
            accentedText = current
        }

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholder.textColor = UIColor(Palette.textDim)
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
                placeholder.topAnchor.constraint(equalTo: topAnchor),
            ])
        }

        func configureTypography() {
            let size = ComposerStyle.fontSize * Typography.scale
            guard font?.pointSize != size || lineHeight != ComposerStyle.lineHeight || composerAttributes.isEmpty
            else { return }
            composerAttributes = ComposerTextMetrics.attributes()
            let face = composerAttributes[.font] as? UIFont ?? .systemFont(ofSize: size)
            let selection = selectedRange
            attributedText = NSAttributedString(string: text ?? "", attributes: composerAttributes)
            accentsReset()
            typingAttributes = composerAttributes
            selectedRange = selection
            lineHeight = ComposerStyle.lineHeight
            placeholder.font = face
        }

        func setPlaceholder(_ text: String) {
            placeholder.attributedText = NSAttributedString(
                string: text,
                attributes: composerAttributes.merging([.foregroundColor: UIColor(Palette.textDim)]) { _, new in new })
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if onPasteFile != nil, action == #selector(paste(_:)), PastedFile.pasteboardType() != nil {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard onPasteFile != nil else {
                super.paste(sender)
                return
            }
            // Text wins when the pasteboard carries both. Copying an image out of Safari
            // registers a URL alongside the image, and a composer that swallowed the item
            // as a file dropped the text the user was actually after.
            //
            // A FILE URL overrides that: Finder and Files put the path on the pasteboard
            // beside the file, so deferring to text there pasted "/Users/…/main.pdf" and
            // attached nothing — which is exactly how Command-V looked broken on Mac and
            // iPad.
            if PastedFile.pasteboardHasFileURL() {
                if let type = PastedFile.pasteboardType(),
                   let provider = UIPasteboard.general.itemProviders.first(where: {
                       $0.hasItemConformingToTypeIdentifier(type.identifier)
                   }) {
                    _ = onPasteFile?(provider)
                }
                // Consumed either way. A decline here means the cap, a load already in
                // flight, or a pane with no named agent — each of which says so in the
                // note. Falling through would ALSO drop the path into the composer, which
                // is the outcome this whole change exists to remove.
                return
            }
            if !UIPasteboard.general.hasStrings, let type = PastedFile.pasteboardType(),
               let provider = UIPasteboard.general.itemProviders.first(where: {
                   $0.hasItemConformingToTypeIdentifier(type.identifier)
               }),
               onPasteFile?(provider) == true
            {
                return
            }
            super.paste(sender)
        }

        private var shouldRevealCaretAfterLayout = false

        /// The height this text needs at `width`, measured from the STRING — not from
        /// `UITextView.sizeThatFits`.
        ///
        /// `sizeThatFits` on a text view answers differently depending on `isScrollEnabled`
        /// and on how much TextKit has lazily laid out, so while it drove the SwiftUI height
        /// the box could still report a two-line height with three lines of text in it: the
        /// third line — the one being typed — was clipped away, and typing looked like it did
        /// nothing until a fourth line made the view scrollable and dragged the caret back
        /// into view. A layout-independent measurement cannot lag the text.
        func fittingHeight(for width: CGFloat) -> CGFloat {
            let padding = 2 * textContainer.lineFragmentPadding
            let usable = max(1, width - textContainerInset.left - textContainerInset.right - padding)
            return ComposerTextMetrics.height(of: text ?? "", width: usable,
                                              attributes: composerAttributes, lineHeight: lineHeight)
        }

        /// Scrolling stays ON at every height. It used to be toggled with the content, which
        /// meant the caret could not be scrolled into view in exactly the state where it had
        /// gone out of view. Bouncing is what actually tracks the content, and a content that
        /// fits is pinned back to the top so a stale offset can never blank the field.
        func refreshScrollMode() {
            guard bounds.width > 0 else { return }
            let overflows = fittingHeight(for: bounds.width) > maximumHeight + 0.5
            alwaysBounceVertical = overflows
            if !overflows, contentOffset.y != 0 {
                setContentOffset(.zero, animated: false)
            }
        }

        func requestCaretReveal() {
            shouldRevealCaretAfterLayout = true
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refreshScrollMode()
            guard shouldRevealCaretAfterLayout else { return }
            shouldRevealCaretAfterLayout = false
            guard let selection = selectedTextRange else { return }
            let caret = caretRect(for: selection.end).insetBy(dx: 0, dy: -4)
            scrollRectToVisible(caret, animated: false)
        }


        func updatePlaceholder() {
            placeholder.isHidden = !text.isEmpty
        }
    }
}
