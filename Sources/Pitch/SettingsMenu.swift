import AppKit

/// The gear's dropdown.
///
/// Pitch has three settings, which is not a window's worth. A dropdown keeps them
/// where the click already is — the same shape InOut's gear uses — and costs the
/// user no context switch to a separate dialog and back.
@MainActor
final class SettingsMenu: NSObject {
    private let restore: () -> Void
    private let arrange: () -> Void
    private let updater: any UpdateChecking

    /// - Parameter restore: runs `Restore Defaults`.
    /// - Parameter arrange: opens Display Arrangement.
    /// - Parameter updater: owns the automatic-update switch.
    ///
    /// Both are injected rather than reached for, so this menu never touches a
    /// display itself and never brings another app forward: the controller owns
    /// every write to the hardware, and it is the only thing that knows the
    /// floating panel has to be closed before something else takes the screen.
    init(
        restore: @escaping () -> Void, arrange: @escaping () -> Void,
        updater: any UpdateChecking
    ) {
        self.restore = restore
        self.arrange = arrange
        self.updater = updater
    }

    /// - Parameter gear: the button this drops out of. It stays on screen, and
    ///   so does the panel behind it — see `StatusMenuController.openSettings`.
    /// - Parameter displayCount: how many displays are online, which decides
    ///   whether there is an arrangement to open at all.
    func show(from gear: NSView, displayCount: Int) {
        let menu = menu(displayCount: displayCount)
        guard let window = gear.window else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.gap), in: gear)
            return
        }
        // Placed in screen coordinates, because AppKit never lets a menu cover
        // the screen's edge: given a point with too little room below it, it
        // slides the whole menu up — over the gear and the pointer, which is
        // what happened the moment a third item made the menu taller. The panel
        // hangs from the menu bar and a display with a long mode list makes it
        // nearly screen-high, so the gear can sit close to the bottom edge.
        let gearRect = window.convertToScreen(gear.convert(gear.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let origin = Self.origin(gear: gearRect, menuSize: menu.size, visible: visible)
        menu.popUp(positioning: nil, at: origin, in: nil)
    }

    /// The menu's top-left corner, in screen coordinates: just under the gear
    /// when the whole menu fits there, otherwise just above it, so the menu
    /// never covers the glyph it dropped out of.
    static func origin(gear: NSRect, menuSize: NSSize, visible: NSRect) -> NSPoint {
        let below = gear.minY - gap
        if below - menuSize.height >= visible.minY {
            return NSPoint(x: gear.minX, y: below)
        }
        return NSPoint(x: gear.minX, y: gear.maxY + gap + menuSize.height)
    }

    /// Built fresh on every click, because `LaunchAtLogin` is read from the
    /// system rather than remembered and its answer can change between opens —
    /// and so can the number of displays.
    ///
    /// Separate from `show(from:displayCount:)` so the contents can be checked
    /// without a screen. `popUp` opens a tracking session and does not return
    /// until the user dismisses it, so a menu built only inside `show` could be
    /// verified no other way than by eye.
    func menu(displayCount: Int) -> NSMenu {
        let menu = NSMenu()
        // Off, because this menu decides for itself which items are live.
        // Left on — the default — AppKit recomputes `isEnabled` from each
        // item's target and selector just before the menu draws, throwing away
        // every value set below: the Start at Login item would render clickable
        // in the one state where clicking it cannot possibly work.
        menu.autoenablesItems = false

        // Arranging one display is not a thing you can do, and System Settings
        // agrees: with a single display attached its Displays pane offers no
        // arrangement at all. An item that led somewhere empty would be worse
        // than no item, so on one display there is none.
        if displayCount > 1 {
            let arrangeItem = NSMenuItem(
                title: Self.arrangementTitle, action: #selector(arrangePressed),
                keyEquivalent: "")
            arrangeItem.target = self
            menu.addItem(arrangeItem)
            // The rule separates the one item that leaves Pitch from the two
            // that change it.
            menu.addItem(.separator())
        }

        let launch = NSMenuItem(
            title: "Start at Login", action: #selector(toggleLaunch), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        // Approval is the system's to give; clicking again cannot grant it.
        launch.isEnabled = LaunchAtLogin.status != .requiresApproval
        // The explanation lives in a tooltip rather than a line of its own: a
        // disabled toggle with no reason is a dead end, but a permanent caption
        // under a two-item menu is clutter for the case that never needs it.
        launch.toolTip = LaunchAtLogin.note
        menu.addItem(launch)

        // Read from the updater on every build, like Start at Login: Sparkle
        // persists the choice itself, so nothing here can drift from it.
        let updates = NSMenuItem(
            title: Self.updatesTitle, action: #selector(toggleUpdates), keyEquivalent: "")
        updates.target = self
        updates.state = updater.automaticallyChecks ? .on : .off
        menu.addItem(updates)

        let restoreItem = NSMenuItem(
            title: "Restore Defaults", action: #selector(restorePressed), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        menu.addItem(Self.note("Pitch \(version as? String ?? "—")"))

        return menu
    }

    /// The title of the item that opens System Settings, shared with the test
    /// that checks when it appears.
    static let arrangementTitle = "Display Arrangement…"

    /// The automatic-update item's title, shared with the tests that find it.
    static let updatesTitle = "Check for Updates Automatically"

    /// Breathing room between the gear and the menu that drops out of it.
    static let gap: CGFloat = 4

    /// The version line at the bottom: information, not a command.
    ///
    /// `isEnabled = false` is what keeps this unclickable, and it holds only
    /// because `menu(displayCount:)` turns `autoenablesItems` off. The nil
    /// action is belt and braces: it would disable the item on its own under
    /// auto-enabling too.
    ///
    /// The font is stated rather than left out. An `attributedTitle` replaces
    /// the item's text wholesale, so AppKit stops supplying the menu font and
    /// draws exactly what these attributes say — omitting the font would fall
    /// back to 12pt Helvetica, and naming a size would pin the line while every
    /// other item in the menu still follows the user's menu-font setting. Only
    /// the colour is meant to differ.
    private static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        return item
    }

    @objc private func toggleLaunch() {
        let wanted = !LaunchAtLogin.isEnabled
        do {
            try LaunchAtLogin.set(wanted)
        } catch {
            // The next open re-reads the system, so the toggle corrects itself.
            // Saying nothing would be the worst outcome: the user would believe
            // Pitch will start at login when it will not.
            let alert = NSAlert()
            alert.messageText = wanted
                ? "Pitch could not be set to start at login"
                : "Pitch could not be removed from login items"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func toggleUpdates() {
        updater.automaticallyChecks.toggle()
    }

    @objc private func restorePressed() {
        restore()
    }

    @objc private func arrangePressed() {
        arrange()
    }
}
