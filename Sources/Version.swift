import Foundation
import MachO

// The version is stamped into the app bundle's Info.plist at install time, so a
// plain source build (which has no bundle) reports "dev". Bundle.main cannot be
// used: the CLI is invoked through a symlink on PATH, which it does not resolve,
// leaving it pointed at the symlink's directory instead of the bundle.
private func bundleVersion() -> String? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }

    // <name>.app/Contents/MacOS/<executable> → <name>.app
    let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    let bundleURL = executable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return Bundle(url: bundleURL)?
        .infoDictionary?["CFBundleShortVersionString"] as? String
}

let appVersion = bundleVersion() ?? "dev"
