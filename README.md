# Hop for iOS

iOS client for the `hop/1` local file-transfer protocol used by Hop for Windows and Android.
The original Hop renderer and animations are reused with a native UIKit/WebKit bridge.

Features: local device radar, file and photo selection, streaming transfers, incoming approval,
remembered devices, Russian/English, light/dark appearance and multiple recipients.
Received files are available in Files → On My iPhone → Hop.

Keep the app in the foreground for discovery and receiving. Transfers use HTTP on a trusted
local network; this is not native Apple AirDrop and has no cloud relay.

Build with Xcode 16+, Swift 5 mode and XcodeGen: `xcodegen generate`, then open Hop.xcodeproj.
GitHub Actions runs core tests, builds and launches the iOS simulator, tests the HTTP receiver,
and exports an **unsigned** device IPA. Sign with your own Apple Account before installing.

Original desktop Hop UI: 0xCodez, MIT. Native iOS client: MIT.
