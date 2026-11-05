import AppKit

/// Non-activating panel: clicking a card never steals focus from the app the user is working in.
final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class QuickAccessController {
    public static let shared = QuickAccessController()

    private final class Card {
        var item: CapturedItem
        let panel: QuickAccessPanel
        let view: QuickAccessCardView
        var displayID: CGDirectDisplayID?
        var autoCloseTimer: Timer?
        var placed = false

        init(item: CapturedItem, panel: QuickAccessPanel, view: QuickAccessCardView, displayID: CGDirectDisplayID?) {
            self.item = item
            self.panel = panel
            self.view = view
            self.displayID = displayID
        }
    }

    /// Index 0 is the newest card (bottom of the stack).
    private var cards: [Card] = []

    /// IDs of items currently shown as cards (protected from history pruning).
    public var openItemIDs: Set<UUID> { Set(cards.map { $0.item.id }) }
    private var closedItems: [CapturedItem] = []
    private var lastLayoutKey = ""
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .snapframeItemUpdated, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? CapturedItem else { return }
            MainActor.assumeIsolated { self?.itemUpdated(item) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.cards.isEmpty, self.layoutKey != self.lastLayoutKey else { return }
                self.relayout(animated: true)
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout(animated: false) }
        })
    }

    // MARK: - Public API

    /// Adds a floating thumbnail card for the item to the Quick Access stack.
    public func show(_ item: CapturedItem) {
        if let existing = cards.first(where: { $0.item.id == item.id }) {
            existing.item = item
            existing.view.apply(item: item)
            restartAutoClose(existing)
            return
        }
        closedItems.removeAll { $0.id == item.id }
        let screen = Prefs.bool(PrefKey.qaMoveToActiveScreen) ? NSScreen.underMouse : NSScreen.main
        let card = makeCard(item, screen: screen ?? NSScreen.main)
        // One stack: with "move to active screen" the existing cards follow the new card.
        if Prefs.bool(PrefKey.qaMoveToActiveScreen), let id = card.displayID {
            for other in cards where other.displayID != id {
                other.displayID = id
                other.placed = false
            }
        }
        cards.insert(card, at: 0)
        relayout(animated: true)
        restartAutoClose(card)
    }

    /// Re-opens the most recently closed card.
    public func restoreLastClosed() {
        let fm = FileManager.default
        while let item = closedItems.popLast() {
            guard fm.fileExists(atPath: item.fileURL.path) else { continue }
            show(item)
            return
        }
        NSSound.beep()
    }

    // MARK: - Cards

    private func makeCard(_ item: CapturedItem, screen: NSScreen?) -> Card {
        let view = QuickAccessCardView(item: item)
        let panel = QuickAccessPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = view
        let card = Card(item: item, panel: panel, view: view, displayID: screen?.displayID)

        view.onCopy = { [weak self, weak card] in
            guard let card else { return }
            Clipboard.copy(card.item)
            card.view.flash("Copied")
            self?.restartAutoClose(card)
        }
        view.onSave = { [weak self, weak card] ask in
            guard let self, let card else { return }
            self.save(card, ask: ask || Prefs.enumValue(PrefKey.qaSaveBehavior, SaveBehavior.exportLocation) == .ask)
        }
        view.onPrimaryEdit = { [weak card] in
            guard let card else { return }
            if card.item.kind == .image { AnnotationEditor.open(card.item) }
            else { VideoEditor.open(card.item) }
        }
        view.onPin = { [weak card] in
            guard let card else { return }
            PinController.shared.pin(card.item)
        }
        view.onClose = { [weak self, weak card] in
            guard let self, let card else { return }
            self.close(card)
        }
        view.onHoverChanged = { [weak self, weak card] hovering in
            guard let self, let card else { return }
            if hovering { card.autoCloseTimer?.invalidate(); card.autoCloseTimer = nil }
            else { self.restartAutoClose(card) }
        }
        view.dragURL = { [weak card] in card.flatMap { Clipboard.namedCopy(of: $0.item) } }
        view.onDragFinished = { [weak self, weak card] succeeded in
            guard let self, let card, succeeded, Prefs.bool(PrefKey.qaCloseAfterDragging),
                  !NSEvent.modifierFlags.contains(.option) else { return }
            self.close(card)
        }
        return card
    }

    private func save(_ card: Card, ask: Bool) {
        // Exporter may run a modal save panel; keep the card from auto-closing underneath it.
        card.autoCloseTimer?.invalidate()
        if let url = Exporter.save(card.item, ask: ask) {
            card.item.savedURL = url
            card.view.flash("Saved")
        }
        restartAutoClose(card)
    }

    private func close(_ card: Card) {
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        cards.remove(at: index)
        card.autoCloseTimer?.invalidate()
        card.autoCloseTimer = nil
        closedItems.append(card.item)
        if closedItems.count > 20 { closedItems.removeFirst() }

        let position = currentPosition
        let slide = QuickAccessLayout.slideFrame(for: card.panel.frame, position: position)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            card.panel.animator().setFrame(slide, display: true)
            card.panel.animator().alphaValue = 0
        }, completionHandler: { [panel = card.panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.close()
            }
        })
        relayout(animated: true)
    }

    private func itemUpdated(_ item: CapturedItem) {
        guard let card = cards.first(where: { $0.item.id == item.id }) else { return }
        card.item = item
        card.view.apply(item: item)
        relayout(animated: true)
    }

    // MARK: - Auto close

    private func restartAutoClose(_ card: Card) {
        card.autoCloseTimer?.invalidate()
        card.autoCloseTimer = nil
        guard Prefs.bool(PrefKey.qaAutoClose) else { return }
        let interval = max(1, Prefs.double(PrefKey.qaAutoCloseInterval))
        let id = card.item.id
        card.autoCloseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let card = self.cards.first(where: { $0.item.id == id }) else { return }
                self.autoClose(card)
            }
        }
    }

    private func autoClose(_ card: Card) {
        let action = Prefs.enumValue(PrefKey.qaAutoCloseAction, AutoCloseAction.saveAndClose)
        // Never pop a save dialog out of nowhere: with "ask for name" on, auto-close just closes.
        if action == .saveAndClose, card.item.savedURL == nil, !Prefs.bool(PrefKey.askNameAfterCapture),
           let url = Exporter.save(card.item) {
            card.item.savedURL = url
        }
        close(card)
    }

    // MARK: - Layout

    private var currentPosition: QuickAccessPosition {
        Prefs.enumValue(PrefKey.qaPosition, QuickAccessPosition.left)
    }

    private var layoutKey: String { "\(currentPosition.rawValue)-\(Prefs.int(PrefKey.qaOverlaySize))" }

    private func screen(for card: Card) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == card.displayID } ?? NSScreen.main
    }

    private func relayout(animated: Bool) {
        lastLayoutKey = layoutKey
        let position = currentPosition
        let tick = Prefs.int(PrefKey.qaOverlaySize)

        // Group by screen, keeping newest-first order within each stack.
        var groups: [(NSScreen, [Card])] = []
        for card in cards {
            guard let screen = screen(for: card) else { continue }
            if let i = groups.firstIndex(where: { $0.0 === screen }) { groups[i].1.append(card) }
            else { groups.append((screen, [card])) }
        }

        for (screen, group) in groups {
            let visible = screen.visibleFrame
            let sizes = group.map { card -> CGSize in
                let s = card.item.pointSize
                return QuickAccessLayout.cardSize(tick: tick, aspect: s.height > 0 ? s.width / s.height : 1.6)
            }
            let frames = QuickAccessLayout.frames(sizes: sizes, in: visible, position: position)
            for (card, frame) in zip(group, frames) {
                place(card, at: frame, visible: QuickAccessLayout.fits(frame, in: visible),
                      position: position, animated: animated)
            }
        }
    }

    private func place(_ card: Card, at frame: CGRect, visible: Bool, position: QuickAccessPosition, animated: Bool) {
        let panel = card.panel
        guard visible else {
            // Overflow: older cards that no longer fit wait until space frees up.
            if panel.isVisible { panel.orderOut(nil) }
            card.placed = false
            return
        }
        if !card.placed {
            card.placed = true
            panel.alphaValue = 0
            panel.setFrame(animated ? QuickAccessLayout.slideFrame(for: frame, position: position) : frame, display: false)
            panel.orderFrontRegardless()
        }
        guard animated else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }
}
