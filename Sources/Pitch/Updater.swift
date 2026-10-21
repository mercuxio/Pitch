import Sparkle

/// The one update setting the gear menu shows.
///
/// A protocol so `SettingsMenu` can be built and checked without starting
/// Sparkle: the real updater launches a background scheduler and may put up its
/// own permission prompt, neither of which belongs in a test run.
@MainActor
protocol UpdateChecking: AnyObject {
    var automaticallyChecks: Bool { get set }
}

/// Wraps Sparkle the way Sniffcast does: the updater starts with the app, and
/// the only thing the rest of Pitch sees is the automatic-check switch.
///
/// Updates come from the appcast named by `SUFeedURL` and are verified against
/// `SUPublicEDKey`, both in `Resources/Info.plist`. A found update is offered
/// in Sparkle's own window; nothing installs without the user saying so.
@MainActor
final class Updater: UpdateChecking {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// Read from Sparkle each time rather than remembered, so the menu agrees
    /// with whatever Sparkle has persisted.
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
