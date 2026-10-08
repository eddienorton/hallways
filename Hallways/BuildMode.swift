import Foundation

/// The single source of truth for Developer vs Release behavior.
///
/// - Debug (Xcode Run): the development workshop. Developer tools are
///   available — Decorator, grid editor / Dev Map, floor transport,
///   developer reset, admission/prologue toggles, testing shortcuts.
/// - Release (Archive / TestFlight / App Store): the intended player
///   experience. Every developer entry point is hidden AND disabled.
///
/// BuildMode must NEVER alter gameplay rules, story progression,
/// admission, missions, or persistence semantics. It only decides
/// whether developer tools are reachable. Decorator implementation and
/// its stored data are untouched in Release — they are simply
/// unreachable.
enum BuildMode {
    #if DEBUG
    static let developerTools = true
    #else
    static let developerTools = false
    #endif
}
