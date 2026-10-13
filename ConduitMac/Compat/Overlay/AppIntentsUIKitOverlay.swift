// Intentionally empty. The SDK declares a cross-import overlay for
// AppIntents + a module named UIKit (`_AppIntents_UIKit`). Our UIKit shim
// module (see UIKitCompat) triggers it, and macOS has no such overlay, so
// any file importing AppIntents fails to compile. This empty module
// satisfies the lookup.
