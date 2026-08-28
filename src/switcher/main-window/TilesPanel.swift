import Cocoa

class TilesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    static var maxPossibleThumbnailSize = NSSize.zero
    static var maxPossibleAppIconSize = NSSize.zero
    static var shared: TilesPanel!
    private var frozenTopCenter: NSPoint?
    private var highWaterHeight: CGFloat = 0

    convenience init() {
        self.init(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        delegate = self
        isFloatingPanel = true
        animationBehavior = .none
        hidesOnDeactivate = false
        titleVisibility = .hidden
        backgroundColor = .clear
        TilesView.initialize()
        contentView! = TilesView.contentView
        // triggering AltTab before or during Space transition animation brings the window on the Space post-transition
        collectionBehavior = .canJoinAllSpaces
        // 2nd highest level possible; this allows the app to go on top of context menus
        // highest level is .screenSaver but makes drag and drop on top the main window impossible
        level = .popUpMenu
        // helps filter out this window from the thumbnails
        setAccessibilitySubrole(.unknown)
        // for VoiceOver
        setAccessibilityLabel(App.name)
        updateAppearance()
        Self.shared = self
    }

    func updateAppearance() {
        hasShadow = Appearance.enablePanelShadow
        appearance = NSAppearance(named: Appearance.currentTheme == .dark ? .vibrantDark : .vibrantLight)
        TilesPanelMirrors.scheduleSync()
    }

    func updateContents(_ preservedScrollOrigin: CGPoint?) {
        caTransaction {
            TilesView.updateItemsAndLayout(preservedScrollOrigin)
            guard SwitcherSession.isActive else { return }
            setContentSize(TilesView.contentView.frame.size)
            guard SwitcherSession.isActive else { return }
            repositionOrFreeze()
        }
        // prevent further AppKit work
        TilesView.clearNeedsLayout()
        TilesPanelMirrors.scheduleSync()
    }


    private func repositionOrFreeze() {
        let size = frame.size
        guard TilesView.isSearchModeOn else {
            NSScreen.preferred.repositionPanel(self)
            resetFrozenPosition()
            return
        }
        if size.height > highWaterHeight {
            NSScreen.preferred.repositionPanel(self)
            highWaterHeight = size.height
            frozenTopCenter = NSPoint(x: frame.midX, y: frame.maxY)
        } else if let topCenter = frozenTopCenter {
            setFrameOrigin(NSPoint(x: topCenter.x - size.width * 0.5, y: topCenter.y - size.height))
        }
    }

    func resetFrozenPosition() {
        frozenTopCenter = nil
        highWaterHeight = 0
    }

    override func orderOut(_ sender: Any?) {
        TilesView.clearNeedsLayout()
        TilesPanelMirrors.hide()
        if Preferences.fadeOutAnimation {
            NSAnimationContext.runAnimationGroup(
                { _ in animator().alphaValue = 0 },
                completionHandler: { super.orderOut(sender) }
            )
        } else {
            // orderOut requires WindowServer. Let's hide before calling it, in case it lags
            alphaValue = 0
            super.orderOut(sender)
        }
    }

    func show() {
        updateAppearance()
        // The panel may have been hidden (alpha=0) by `App.showUiOrCycleSelection` on a
        // cross-shortcut summon to mask the rebuild. Reveal it atomically now that contents
        // and Appearance are in their final state.
        alphaValue = 1
        makeKeyAndOrderFront(nil)
        TilesPanelMirrors.show()
        // The artificial key-repeat measures its initial-delay grace from when the panel could be SEEN, and this
        // is the only anchor for that which is guaranteed to exist — see `SwitcherSession.panelShownAt`. Set
        // once per summon (a re-show within one session must not restart the grace under the user's fingers).
        if let session = SwitcherSession.current, session.panelShownAt == nil {
            session.panelShownAt = ProcessInfo.processInfo.systemUptime
        }
        ContextMenuEvents.toggle(true)
        CursorEvents.toggle(true)
        DispatchQueue.main.async { TilesView.scrollView.flashScrollers() }
    }

    static func maxThumbnailsWidth(_ screen: NSScreen = NSScreen.preferred) -> CGFloat {
        let screenWidth = Preferences.showOnScreen == .all
            ? NSScreen.screens.map(\.frame.width).min() ?? screen.frame.width
            : screen.frame.width
        if Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .titles,
           let readableWidth = TilesView.layoutCache.comfortableReadabilityWidth {
            return (
                min(
                    screenWidth * Appearance.maxWidthOnScreen,
                    readableWidth + Appearance.intraCellPadding * 2 + Appearance.appIconLabelSpacing + Appearance.iconSize
                    // widthOfLongestTitle + Appearance.intraCellPadding * 2 + Appearance.appIconLabelSpacing + Appearance.iconSize
                ) - Appearance.windowPadding * 2
            ).rounded()
        }
        return (screenWidth * Appearance.maxWidthOnScreen - Appearance.windowPadding * 2).rounded()
    }

    static func maxThumbnailsHeight(_ screen: NSScreen = NSScreen.preferred) -> CGFloat {
        let screenHeight = Preferences.showOnScreen == .all
            ? NSScreen.screens.map(\.frame.height).min() ?? screen.frame.height
            : screen.frame.height
        return (screenHeight * Appearance.maxHeightOnScreen - Appearance.windowPadding * 2).rounded()
    }

    static func updateMaxPossibleThumbnailSize() {
        let (w, h) = NSScreen.screens.reduce((CGFloat.zero, CGFloat.zero)) { acc, screen in
            (max(acc.0, TileView.maxThumbnailWidth(screen) * screen.backingScaleFactor),
            max(acc.1, TileView.maxThumbnailHeight(screen) * screen.backingScaleFactor))
        }
        maxPossibleThumbnailSize = NSSize(width: w.rounded(), height: h.rounded())
    }

    static func updateMaxPossibleAppIconSize() {
        let (w, h) = NSScreen.screens.reduce((CGFloat.zero, CGFloat.zero)) { acc, screen in
            // in Thumbnails Appearance, AppIcons can be used for windowless apps, thus much bigger than the app icon near the title
            if Preferences.effectiveAppearanceStyle(SwitcherSession.activeShortcutIndex) == .thumbnails {
                return (max(acc.0, TileView.maxThumbnailWidth(screen) * screen.backingScaleFactor),
                    max(acc.1, TileView.maxThumbnailHeight(screen) * screen.backingScaleFactor))
            } else {
                let size = TileView.iconSize(screen)
                return (max(acc.0, size.width * screen.backingScaleFactor),
                    max(acc.1, size.height * screen.backingScaleFactor))
            }
        }
        maxPossibleAppIconSize = NSSize(width: w.rounded(), height: h.rounded())
    }
}

/// The interactive switcher remains one AppKit view hierarchy (and one key panel). Other displays receive
/// a synchronized, non-interactive image of it. This avoids duplicating responder, search, hover, and
/// selection state while still making the complete switcher visible everywhere at the same time.
enum TilesPanelMirrors {
    private static var panels = [String: TilesMirrorPanel]()
    private static var syncScheduled = false
    private static var failedSnapshotAttempts = 0

    static func show() {
        guard Preferences.showOnScreen == .all, NSScreen.screens.count > 1 else {
            hide()
            return
        }
        failedSnapshotAttempts = 0
        scheduleSync()
    }

    static func scheduleSync() {
        guard Preferences.showOnScreen == .all, SwitcherSession.isActive,
              TilesPanel.shared?.isVisible == true, TilesPanel.shared.alphaValue > 0,
              !syncScheduled else { return }
        syncScheduled = true
        // Wait until the current layout/highlight/thumbnail Core Animation transaction has committed.
        DispatchQueue.main.async {
            syncScheduled = false
            synchronizeNow()
        }
    }

    static func hide() {
        syncScheduled = false
        failedSnapshotAttempts = 0
        panels.values.forEach {
            $0.orderOut(nil)
            $0.releaseImage()
        }
    }

    private static func synchronizeNow() {
        guard Preferences.showOnScreen == .all, SwitcherSession.isActive,
              let sourcePanel = TilesPanel.shared, sourcePanel.isVisible, sourcePanel.alphaValue > 0,
              let sourceView = sourcePanel.contentView
        else { return }
        guard let image = snapshot(sourcePanel) else {
            retrySnapshotIfNeeded()
            return
        }
        failedSnapshotAttempts = 0
        let primaryKey = screenKey(sourcePanel.screen ?? NSScreen.preferred)
        let targetScreens = NSScreen.screens.filter { screenKey($0) != primaryKey }
        let targetKeys = Set(targetScreens.map(screenKey))
        for key in Set(panels.keys).subtracting(targetKeys) {
            panels.removeValue(forKey: key)?.orderOut(nil)
        }
        for screen in targetScreens {
            let key = screenKey(screen)
            let panel = panels[key] ?? {
                let panel = TilesMirrorPanel()
                panels[key] = panel
                return panel
            }()
            panel.show(image, sourceView.frame.size, screen, sourcePanel)
        }
    }

    private static func retrySnapshotIfNeeded() {
        guard AppearanceTestable.shouldRetryMirrorSnapshot(failedSnapshotAttempts) else { return }
        failedSnapshotAttempts += 1
        // A panel ordered front for the first time can precede its WindowServer surface by one frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { scheduleSync() }
    }

    private static func snapshot(_ panel: NSPanel) -> CGImage? {
        guard panel.windowNumber > 0 else { return nil }
        // Tiles and thumbnails are layer-backed, so NSView.cacheDisplay() only captures the panel's
        // background. Capture the composited WindowServer surface instead; this is the same path used
        // for regular window thumbnails and preserves every tile, badge, and selection highlight.
        var windowId = CGWindowID(panel.windowNumber)
        return (CGSHWCaptureWindowList(CGS_CONNECTION, &windowId, 1,
            [.ignoreGlobalClipShape, .bestResolution, .fullSize]).takeRetainedValue() as! [CGImage]).first
    }

    private static func screenKey(_ screen: NSScreen) -> String {
        if let uuid = screen.cachedUuid() { return uuid as String }
        return String(describing: screen.frame)
    }
}

private final class TilesMirrorPanel: NSPanel {
    private let imageView = LightImageView()
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        isFloatingPanel = true
        animationBehavior = .none
        hidesOnDeactivate = false
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        collectionBehavior = .canJoinAllSpaces
        level = .popUpMenu
        setAccessibilitySubrole(.unknown)
        contentView = imageView
    }

    func show(_ image: CGImage, _ size: NSSize, _ screen: NSScreen, _ sourcePanel: TilesPanel) {
        imageView.updateContents(.cgImage(image), size)
        setContentSize(size)
        hasShadow = sourcePanel.hasShadow
        appearance = sourcePanel.appearance
        alphaValue = 1
        screen.repositionPanel(self)
        if !isVisible { orderFrontRegardless() }
    }

    func releaseImage() {
        imageView.releaseImage()
    }
}

extension TilesPanel: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // other windows can steal key focus from alt-tab; we make sure that if it's active, if keeps key focus
        // dispatching to the main queue is necessary to introduce a delay in scheduling the makeKey; otherwise it is ignored
        DispatchQueue.main.async {
            if SwitcherSession.isActive {
                TilesPanel.shared.makeKeyAndOrderFront(nil)
            }
            MainMenu.toggle(true)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // we toggle the mainMenu off when showing the main window
        // this avoids command+q from quitting AltTab itself, or command+p from printing
        DispatchQueue.main.async {
            MainMenu.toggle(false)
            if TilesView.isSearchEditing {
                MainMenu.toggleEditMenu(true)
            }
        }
        // Refresh the window model once the main run loop next goes idle after showing — i.e. after AppKit has
        // finished ALL the show's main-thread work for this frame. A one-shot kCFRunLoopBeforeWaiting observer
        // fires only when the loop is about to sleep, so it provably can't preempt the render, yet still runs
        // ASAP with no timer guess. (Replaces a 0.25s timer, then a CATransaction-commit hook that fired mid
        // -render and let the reconcile's re-layout race the first frame.)
        let refreshObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { observer, _ in
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            Applications.manuallyRefreshAllWindows()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), refreshObserver, .commonModes)
    }
}
