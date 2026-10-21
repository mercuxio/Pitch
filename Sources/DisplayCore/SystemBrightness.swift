import Foundation

extension BrightnessRouter {
    /// The router both the app and `displayctl` use: every real backend, in the
    /// preference order of spec §18.2. One list, so the two can never disagree
    /// about which mechanism drives a display.
    public static func system() -> BrightnessRouter {
        BrightnessRouter(backends: [
            GammaBackend(tables: CoreGraphicsGamma())
        ])
    }
}
