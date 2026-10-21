import AppKit
import Testing

@testable import Pitch

/// The gear dropdown's one rule that is not "always show this".
///
/// `SettingsMenu` is otherwise a list of fixed items, but whether Display
/// Arrangement appears depends on the hardware, and that is the kind of thing
/// that quietly inverts during a refactor and is never noticed — nobody
/// unplugs a monitor to check a menu.
@MainActor
final class FakeUpdater: UpdateChecking {
    var automaticallyChecks: Bool
    init(automaticallyChecks: Bool = false) { self.automaticallyChecks = automaticallyChecks }
}

@MainActor
struct SettingsMenuTests {
    private func settings(
        arrange: @escaping () -> Void = {}, updater: FakeUpdater = FakeUpdater()
    ) -> SettingsMenu {
        SettingsMenu(restore: {}, arrange: arrange, updater: updater)
    }

    private func updatesItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == SettingsMenu.updatesTitle }
    }

    @Test func theUpdateItemSitsDirectlyBelowStartAtLogin() {
        let titles = settings().menu(displayCount: 1).items.map(\.title)
        let login = titles.firstIndex(of: "Start at login")
        let updates = titles.firstIndex(of: SettingsMenu.updatesTitle)
        #expect(login != nil)
        #expect(updates == login.map { $0 + 1 })
    }

    @Test func theUpdateItemIsTickedExactlyWhenAutomaticChecksAreOn() {
        for on in [true, false] {
            let owner = settings(updater: FakeUpdater(automaticallyChecks: on))
            let state = updatesItem(in: owner.menu(displayCount: 1))?.state
            #expect(state == (on ? .on : .off))
        }
    }

    @Test func choosingTheUpdateItemFlipsTheSwitchBothWays() {
        let updater = FakeUpdater(automaticallyChecks: false)
        let owner = settings(updater: updater)
        let item = updatesItem(in: owner.menu(displayCount: 1))

        _ = item.flatMap { $0.target?.perform($0.action!) }
        #expect(updater.automaticallyChecks)

        _ = item.flatMap { $0.target?.perform($0.action!) }
        #expect(!updater.automaticallyChecks)
    }

    @Test func oneDisplayIsNotOfferedAnArrangement() {
        // With a single display System Settings shows no arrangement at all, so
        // the item would open a pane that cannot answer it.
        let titles = settings().menu(displayCount: 1).items.map(\.title)
        #expect(!titles.contains(SettingsMenu.arrangementTitle))
    }

    @Test func twoOrMoreDisplaysAreOfferedAnArrangement() {
        for count in [2, 3, 6] {
            let titles = settings().menu(displayCount: count).items.map(\.title)
            #expect(titles.contains(SettingsMenu.arrangementTitle))
        }
    }

    @Test func theRestOfTheMenuDoesNotDependOnTheDisplayCount() {
        // The arrangement item and its separator are the only difference, so a
        // change that started hiding Start at login on one display would show up
        // here rather than in a bug report.
        for count in [1, 2, 5] {
            let titles = settings().menu(displayCount: count).items.map(\.title)
            #expect(titles.contains("Start at login"))
            #expect(titles.contains("Restore defaults"))
        }
    }

    @Test func pickingArrangementRunsTheInjectedAction() {
        // The controller is what closes the floating panel before System
        // Settings comes forward, so an item wired to nothing would leave the
        // panel sitting on top of the window the user just asked for.
        var fired = 0
        // Held in a local rather than chained off `settings(arrange:)`:
        // `NSMenuItem.target` is a weak reference, so a menu whose owner has
        // already been released has items that point at nothing. The app holds
        // its `SettingsMenu` for the controller's lifetime, which is why this
        // only ever bites a test.
        let owner = settings(arrange: { fired += 1 })
        let menu = owner.menu(displayCount: 2)
        let item = menu.items.first { $0.title == SettingsMenu.arrangementTitle }

        #expect(item?.target != nil)
        _ = item.flatMap { $0.target?.perform($0.action!) }

        #expect(fired == 1)
    }

    @Test func theMenuDecidesItsOwnEnabledStateRatherThanLettingAppKitGuess() {
        // `NSMenu.autoenablesItems` defaults to true, and under it AppKit
        // recomputes every item's enabled state from its target and selector
        // just before the menu draws — discarding whatever the builder set.
        // Start at login turns itself off when macOS is waiting for the user to
        // approve the login item, and that is precisely a case where the item
        // has a target that does respond to the selector, so auto-enabling
        // would put it back. The flag is the whole reason that works.
        //
        // Written as `!flag` rather than `flag == false`: see
        // `boolComparisonsAreInvisibleToTheExpectMacro` in DisplayCoreTests for
        // why the comparison form would pass no matter what the flag held.
        let menu = settings().menu(displayCount: 2)
        #expect(!menu.autoenablesItems)

        // And end to end. `update()` is where auto-enabling would run, and in a
        // process with no responder chain it finds nothing to validate against,
        // so it disables every item it is allowed to touch — including this
        // one, which has both a target and an action and is never disabled by
        // the builder. Surviving `update()` enabled is only possible with the
        // flag off.
        menu.update()
        let restore = menu.items.first { $0.title == "Restore defaults" }
        #expect(restore?.action != nil)
        let restoreIsEnabled = restore?.isEnabled ?? false
        #expect(restoreIsEnabled)
    }

    @Test func theMenuDropsBelowTheGearWhenItFitsThere() {
        let gear = NSRect(x: 100, y: 500, width: 20, height: 20)
        let origin = SettingsMenu.origin(
            gear: gear, menuSize: NSSize(width: 200, height: 100),
            visible: NSRect(x: 0, y: 0, width: 1000, height: 800))

        #expect(origin == NSPoint(x: 100, y: 500 - SettingsMenu.gap))
    }

    @Test func theMenuOpensAboveTheGearWhenThereIsNoRoomBelow() {
        // AppKit would otherwise shift it up itself, over the gear and the
        // pointer. Above means its bottom edge sits just over the glyph.
        let gear = NSRect(x: 100, y: 60, width: 20, height: 20)
        let size = NSSize(width: 200, height: 100)
        let origin = SettingsMenu.origin(
            gear: gear, menuSize: size, visible: NSRect(x: 0, y: 0, width: 1000, height: 800))

        #expect(origin.y - size.height == gear.maxY + SettingsMenu.gap)
        #expect(origin.y - size.height >= gear.maxY)
    }
}
