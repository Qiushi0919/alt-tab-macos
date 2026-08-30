import Cocoa
import Foundation

enum FeedbackKind: Hashable {
    case bug
    case enhancement

    var apiValue: String {
        switch self {
        case .bug: return "bug"
        case .enhancement: return "enhancement"
        }
    }
}

private struct Draft {
    var title: String = ""
    var body: String = ""
}

class FeedbackWindow: NSWindow {
    // Mirror of the caps in server
    // Counted in UTF-16 code units to match the server's String.length check.
    // Keep in sync with the server constants; the server is still the source of truth.
    static let titleMaxLength = 256
    static let bodyMaxLength = 64 * 1024
    static var shared: FeedbackWindow?
    var kind: FeedbackKind = .bug
    var issueTitle: TextArea!
    var body: TextArea!
    var sendButton: NSButton!
    /// Per-kind in-memory drafts. Survive close/reopen so a half-written report isn't lost when
    /// the user steps away. Only cleared when the matching kind submits successfully (server 201).
    private var drafts: [FeedbackKind: Draft] = [:]
    /// Tracks whether the visible content is the form (true) or the kind picker (false). Used to
    /// know whether issueTitle / body reflect the current user-visible input.
    private var formIsVisible = false
    /// Sentinel for in-flight POSTs — `sendCallback` sets it before firing the request, the
    /// completion handler bumps it back to false. Used to avoid double-submits and to decide
    /// whether the error alert is still relevant when a response finally arrives.
    private var isSubmitting = false
    /// Bumped before each update check, and again on any window-state change that
    /// invalidates that check (close, reset, user navigating away). The completion closures
    /// captured by the check compare against this generation and no-op on mismatch — that
    /// stops a late-arriving network response from popping a dialog on a closed window or
    /// a reset picker.
    private var updateCheckGeneration: UInt = 0
    private var bugCard: FeedbackKindCard?
    private var enhancementCard: FeedbackKindCard?
    static var canBecomeKey_ = true
    override var canBecomeKey: Bool { Self.canBecomeKey_ }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.titled, .miniaturizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        setupWindow()
        setFrameAutosaveNameSafely("FeedbackWindow")
        Self.shared = self
        reset()
    }

    /// Returns the window to the kind picker. Drafts are NOT cleared — they're only wiped by a
    /// successful POST. Any in-flight update check is invalidated so its late completion can't
    /// surprise the user. Called from init and from `App.showFeedbackPanel` on each reopen.
    func reset() {
        invalidatePendingUpdateCheck()
        captureCurrentDraft()
        kind = .bug
        showKindPicker()
    }

    private func setupWindow() {
        title = NSLocalizedString("Send feedback", comment: "")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    // MARK: - Draft management

    /// Snapshot the currently-edited textareas into `drafts[kind]`. No-op when the kind picker
    /// is visible (issueTitle/body may still be live but they belong to a now-detached form view
    /// — saving them again would be redundant but harmless; we skip for clarity).
    private func captureCurrentDraft() {
        guard formIsVisible, let issueTitle = issueTitle, let body = body else { return }
        drafts[kind] = Draft(title: issueTitle.stringValue, body: body.stringValue)
    }

    // MARK: - Kind picker (state A)

    private func showKindPicker() {
        formIsVisible = false
        let appIcon = LightImageView()
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        let appIconSize = NSSize(width: 64, height: 64)
        appIcon.updateContents(.cgImage(App.appIcon(for: appIconSize)), appIconSize)
        appIcon.fit(64, 64)

        let subtitle = NSTextField(labelWithString: NSLocalizedString("Help improve AltTab", comment: ""))
        subtitle.textColor = .secondaryLabelColor
        let headerText = StackView([
            BoldLabel(NSLocalizedString("Send feedback", comment: "")),
            subtitle,
        ], .vertical)
        headerText.spacing = GridView.interPadding / 2

        let header = NSStackView(views: [appIcon, headerText])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.spacing = GridView.interPadding
        header.alignment = .centerY

        let bug = FeedbackKindCard(
            symbol: .ladybug,
            iconTint: .systemRed,
            title: NSLocalizedString("Report a bug", comment: ""),
            target: self,
            action: #selector(selectBug))
        let enhancement = FeedbackKindCard(
            symbol: .lightbulb,
            iconTint: .systemOrange,
            title: NSLocalizedString("Suggest a change", comment: ""),
            target: self,
            action: #selector(selectEnhancement))
        bugCard = bug
        enhancementCard = enhancement

        let cards = NSStackView(views: [bug, enhancement])
        cards.translatesAutoresizingMaskIntoConstraints = false
        cards.spacing = GridView.interPadding
        cards.orientation = .horizontal
        cards.distribution = .fillEqually

        let discussionsLink = HyperlinkLabel(
            NSLocalizedString("View existing discussions", comment: "") + " →",
            App.repository + "/issues")

        let view = GridView([
            [header],
            [cards],
            [discussionsLink],
        ])
        view.cell(atColumnIndex: 0, rowIndex: 2).xPlacement = .center
        contentView = view.wrappedWithTitlebarPadding()
        setContentSize(contentView!.fittingSize)
    }

    @objc private func selectBug() {
        kind = .bug
        checkForUpdatesAndProceed()
    }

    @objc private func selectEnhancement() {
        kind = .enhancement
        showForm()
    }

    // MARK: - Update check on bug click

    /// Decide whether to show the update alert or the bug form, possibly after a one-time
    /// GitHub round-trip. The check itself only runs once per app session:
    ///   * cache hit → resolve instantly, no spinner
    ///   * cache miss → morph the bug card into a spinner + "Check for updates…" and wait on
    ///     whichever fires first: the GitHub response, or a 5-second timeout
    /// Either branch caches its outcome, so subsequent clicks in this session skip the spinner.
    private func checkForUpdatesAndProceed() {
        let updateChecker = ForkUpdateChecker.shared
        if let cached = updateChecker.cachedResult {
            apply(updateCheckResult: cached)
            return
        }

        updateCheckGeneration &+= 1
        let mine = updateCheckGeneration
        bugCard?.setLoading(NSLocalizedString("Check for updates…", comment: ""))
        enhancementCard?.isEnabled = false

        let proceed: (ForkUpdateChecker.Result) -> Void = { [weak self] result in
            guard let self = self, self.updateCheckGeneration == mine else { return }
            self.updateCheckGeneration &+= 1
            self.bugCard?.setNormal()
            self.enhancementCard?.isEnabled = true
            self.apply(updateCheckResult: result)
        }
        updateChecker.checkForUpdateInformation(completion: proceed)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if updateChecker.cachedResult == nil {
                updateChecker.cachedResult = .upToDate
            }
            proceed(.upToDate)
        }
    }

    private func apply(updateCheckResult result: ForkUpdateChecker.Result) {
        switch result {
        case .updateAvailable(let release): showUpdateAvailableAlert(release: release)
        case .upToDate: showForm()
        }
    }

    private func invalidatePendingUpdateCheck() {
        updateCheckGeneration &+= 1
        bugCard?.setNormal()
        enhancementCard?.isEnabled = true
    }

    // MARK: - Update-available interception

    private func showUpdateAvailableAlert(release: ForkUpdateChecker.Release) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("A new version of AltTab is available", comment: "")
        let format = NSLocalizedString(
            "You're running v%1$@. v%2$@ is available. The bug you're seeing may already be fixed — please update first and check before reporting.",
            comment: "")
        alert.informativeText = String(format: format, App.version, release.version)
        alert.addButton(withTitle: NSLocalizedString("Update now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Report on current version", comment: ""))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            close()
            ForkUpdateChecker.shared.openRelease(release)
        } else {
            showForm()
        }
    }

    // MARK: - Form (state B)

    private func showForm() {
        formIsVisible = true
        let appIcon = LightImageView()
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        let appIconSize = NSSize(width: 64, height: 64)
        appIcon.updateContents(.cgImage(App.appIcon(for: appIconSize)), appIconSize)
        appIcon.fit(64, 64)
        let headerLeft = NSStackView(views: [appIcon, BoldLabel(formTitle())])
        headerLeft.translatesAutoresizingMaskIntoConstraints = false
        headerLeft.spacing = GridView.interPadding
        headerLeft.alignment = .centerY

        let goBack = NSButton(title: "← " + NSLocalizedString("Go back", comment: ""), target: self, action: #selector(goBackToPicker))
        goBack.bezelStyle = .recessed
        goBack.setButtonType(.momentaryPushIn)

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.addView(headerLeft, in: .leading)
        header.addView(goBack, in: .trailing)

        // Form has no Cancel button on purpose: the only ways out are Send (gated by the
        // confirmation alert, whose own Cancel returns here with content intact), the Go back
        // button (returns to the picker, draft preserved), or closing the window (red traffic-
        // light or Escape — also preserves the draft for the next open).
        sendButton = NSButton(title: NSLocalizedString("Create GitHub issue", comment: ""), target: nil, action: #selector(sendCallback))
        sendButton.keyEquivalent = "\r"
        let buttons = StackView([sendButton])
        buttons.spacing = GridView.interPadding

        issueTitle = TextArea(80, 1, titlePlaceholder(), checkEmptyFields, Self.titleMaxLength)
        body = TextArea(80, 12, bodyPlaceholder(), checkEmptyFields, Self.bodyMaxLength)
        // Restore any unsent draft for this kind so the user picks up exactly where they left off.
        if let draft = drafts[kind] {
            issueTitle.stringValue = draft.title
            body.stringValue = draft.body
        }

        let view = GridView([
            [header],
            [NSView()],
            [issueTitle],
            [body],
            [buttons],
        ])
        view.cell(atColumnIndex: 0, rowIndex: 0).xPlacement = .fill
        view.cell(atColumnIndex: 0, rowIndex: 4).xPlacement = .trailing
        contentView = view.wrappedWithTitlebarPadding()
        setContentSize(contentView!.fittingSize)
        checkEmptyFields()
        // Explicit Tab chain: title → body → Create → Go back → title.
        // NSGridView + NSStackView nesting doesn't compute a useful auto-chain across
        // container boundaries; without this, Tab just re-focuses the current field.
        // Disabled views (e.g. sendButton while title/body are empty) are skipped by
        // AppKit automatically, so the cycle gracefully shortens to title → body → Go back.
        issueTitle.nextKeyView = body
        body.nextKeyView = sendButton
        sendButton.nextKeyView = goBack
        goBack.nextKeyView = issueTitle
        makeFirstResponder(issueTitle)
    }

    @objc private func goBackToPicker() {
        captureCurrentDraft()
        showKindPicker()
    }

    private func formTitle() -> String {
        switch kind {
        case .bug: return NSLocalizedString("Report a bug", comment: "")
        case .enhancement: return NSLocalizedString("Suggest a change", comment: "")
        }
    }

    private func titlePlaceholder() -> String {
        switch kind {
        case .bug: return NSLocalizedString("Brief description of the bug", comment: "")
        case .enhancement: return NSLocalizedString("Brief description of the change", comment: "")
        }
    }

    private func bodyPlaceholder() -> String {
        switch kind {
        case .bug: return NSLocalizedString("What did you expect? What happened? Steps to reproduce…", comment: "")
        case .enhancement: return NSLocalizedString("I think the app could be improved with…", comment: "")
        }
    }

    private func checkEmptyFields() {
        if isSubmitting { return }
        sendButton.isEnabled = !body.stringValue.isEmpty && !issueTitle.stringValue.isEmpty
        sendButton.toolTip = sendButton.isEnabled ? "" : NSLocalizedString("Please fill in the form", comment: "")
    }

    // allow to close with the escape key
    @objc func cancel(_ sender: Any?) {
        close()
    }

    /// Cmd+Return submits even when focus is in the multi-line body field (where plain
    /// Return inserts a newline). Convention: Mail compose, Notes, Linear, Slack — anywhere
    /// you compose multi-paragraph text and need a one-handed keyboard submit.
    /// Running before the field editor sees the key means we don't fight TextArea's
    /// Return → newline behavior; we just add a second submit gesture alongside it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if formIsVisible,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "\r",
           let sendButton, sendButton.isEnabled {
            sendButton.performClick(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func sendCallback() {
        if isSubmitting { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Your feedback will be submitted as a public GitHub issue.", comment: "")
        alert.informativeText = NSLocalizedString("A debug profile (versions, settings, hardware) is attached to help diagnose the issue.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Create GitHub issue", comment: ""))
        let cancelButton = alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        if alert.runModal() != .alertFirstButtonReturn { return }
        beginSubmitting()
        // Capture the kind that owns this submission. If the user navigates to the other kind
        // form while the POST is in flight, completion still clears the right draft slot.
        let submittedKind = kind
        URLSession.shared.dataTask(with: prepareRequest()) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let succeeded = status == 201 && error == nil
            if !succeeded {
                Logger.error { "feedback POST failed. status:\(status) response:\(response) error:\(error) data:\(data.flatMap { String(data: $0, encoding: .utf8) })" }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.endSubmitting()
                if succeeded {
                    self.drafts[submittedKind] = nil
                    // If the user is still on the form they submitted, also clear the on-screen
                    // textareas so the visible state matches the now-empty draft.
                    if self.formIsVisible && self.kind == submittedKind {
                        self.issueTitle.stringValue = ""
                        self.body.stringValue = ""
                    }
                    self.close()
                } else {
                    self.showSubmitFailureAlert()
                }
            }
        }.resume()
    }

    private func beginSubmitting() {
        isSubmitting = true
        sendButton.isEnabled = false
        sendButton.title = NSLocalizedString("Sending…", comment: "")
    }

    private func endSubmitting() {
        isSubmitting = false
        sendButton.title = NSLocalizedString("Create GitHub issue", comment: "")
        checkEmptyFields()
    }

    private func showSubmitFailureAlert() {
        // If the user already dismissed the window before the failure came back, skip the alert —
        // surprising them with a modal on a closed-feeling window is worse than swallowing it. The
        // draft is already preserved in `drafts`, so they'll see their text again on next reopen.
        guard isVisible else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Couldn't submit feedback", comment: "")
        alert.informativeText = NSLocalizedString("The server didn't accept the submission. Check your internet connection and try again — your draft is preserved.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    /// The backend owns the final GitHub issue presentation — we just hand it the raw
    /// pieces. Splitting `body` from `debugProfile` means the markdown layout (quoting,
    /// `<details>` wrapping, disclaimer) can change server-side without forcing every
    /// installed AltTab to update.
    private func prepareRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: Endpoints.feedbackUrl)!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try! JSONSerialization.data(withJSONObject: [
            "title": issueTitle.stringValue,
            "body": body.stringValue,
            "kind": kind.apiValue,
            "debugProfile": DebugProfile.make(),
        ])
        return request
    }

    override func close() {
        invalidatePendingUpdateCheck()
        captureCurrentDraft()
        hideAppIfLastWindowIsClosed()
        super.close()
    }
}

// Clickable kind card: icon + bold title inside an NSButton. hitTest is overridden so clicks
// on the inner labels register as a button press rather than being swallowed by the label views.
// Supports a loading state where the icon is replaced by a spinning NSProgressIndicator and the
// title is swapped for a "Check for updates…" style hint while the bug-card's pre-form check runs.
class FeedbackKindCard: NSButton {
    private let iconView: NSView
    private let spinner: NSProgressIndicator
    private let titleLabel: NSTextField
    private let normalTitle: String

    init(symbol: Symbols, iconTint: NSColor, title: String, target: AnyObject?, action: Selector) {
        iconView = Self.makeIcon(symbol: symbol, tint: iconTint)
        let sp = NSProgressIndicator()
        sp.style = .spinning
        sp.controlSize = .regular
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.isDisplayedWhenStopped = false
        sp.isHidden = true
        spinner = sp

        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.alignment = .center
        titleLabel = label
        normalTitle = title

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.target = target
        self.action = action
        bezelStyle = .regularSquare
        isBordered = true
        imagePosition = .noImage
        self.title = ""

        // Fixed-size slot lets the icon and spinner overlap without making the card geometry
        // jump when state changes. 36×36 matches the icon's intrinsic size from makeIcon.
        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(iconView)
        iconSlot.addSubview(spinner)
        NSLayoutConstraint.activate([
            iconSlot.widthAnchor.constraint(equalToConstant: 36),
            iconSlot.heightAnchor.constraint(equalToConstant: 36),
            iconView.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
        ])

        let stack = NSStackView(views: [iconSlot, titleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            widthAnchor.constraint(equalToConstant: 220),
            heightAnchor.constraint(equalToConstant: 130),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ text: String) {
        iconView.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        titleLabel.stringValue = text
        isEnabled = false
    }

    func setNormal() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = false
        titleLabel.stringValue = normalTitle
        isEnabled = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit === self || hit.isDescendant(of: self) {
            return self
        }
        return nil
    }

    // Rendered from the bundled SF Pro Text subset. Template tinting is applied at runtime
    // via contentTintColor — same pattern as PermissionView.
    private static func makeIcon(symbol: Symbols, tint: NSColor) -> NSView {
        let image = NSImage.fromSymbol(symbol, pointSize: 28)
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyUpOrDown
        if #available(macOS 10.14, *) { iv.contentTintColor = tint }
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.fit(36, 36)
        return iv
    }
}
