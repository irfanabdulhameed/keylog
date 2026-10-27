import AppKit

let arguments = CommandLine.arguments
// Also how the updater's debug run reads the version of a freshly installed copy.
if arguments.dropFirst().first == "--version" {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "development build"
    print("Keylog \(version)" + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""))
    exit(0)
}
if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
    Snapshot.run(into: arguments[flag + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
