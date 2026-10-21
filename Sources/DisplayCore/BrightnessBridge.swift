import Darwin
import Foundation

/// The only place Pitch reaches for symbols Apple does not publish.
///
/// Every lookup is optional by construction. A symbol that is missing — renamed,
/// removed, or never present on this hardware — makes its backend report
/// `.unsupported` and the router falls through; it is never a crash and never an
/// error the user sees. That is the whole contract for private API here (spec §18.4).
enum BrightnessBridge {
    /// `dlopen` handle for a framework path, or `nil` if it cannot be loaded.
    static func open(_ path: String) -> UnsafeMutableRawPointer? {
        dlopen(path, RTLD_LAZY)
    }

    /// A C function pointer, or `nil` if the symbol is absent.
    static func function<T>(
        _ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type
    ) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
