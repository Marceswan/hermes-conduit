# macOS port decisions

## D1: UIKit module packaging (Task 1 spike, 2026-10-13)
Result: module named UIKit works, provided the framework product is also named UIKit (PRODUCT_NAME: UIKit, PRODUCT_MODULE_NAME: UIKit). No fallback needed.
Evidence: with PRODUCT_NAME: ConduitUIKitCompat the build failed with
`ProbeApp.swift:2:8: error: Unable to resolve module dependency: 'UIKit'`
(Swift locates a framework module by framework directory name, UIKit.framework, not by module name). After setting PRODUCT_NAME: UIKit: `** BUILD SUCCEEDED **`; Debug products contain UIKit.framework; the app launched (pgrep -x Conduit returned a pid).

## D2: AVAudioSession shadowing (Task 1 spike, 2026-10-13)
Result: same-named class in app target shadows AVFAudio
Evidence: probe declared `final class AVAudioSession` in the app module alongside `import AVFAudio`; no ambiguity error, `** BUILD SUCCEEDED **`.
