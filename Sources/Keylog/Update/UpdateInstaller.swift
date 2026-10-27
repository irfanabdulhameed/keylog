import AppKit
import KeylogCore
import Security

/// Why an update didn't work, in words for the window.
enum UpdateFailure: Error, Equatable {
    case offline
    case timedOut
    case unreachable
    case status(Int)
    /// The disk image's server answered with an error.
    case downloadStatus(Int)
    case unreadable
    case incomplete
    case damaged
    case notKeylog
    /// Signed by a different certificate than this copy: macOS would drop Input Monitoring.
    case signedDifferently
    case notNewer
    case couldntReplace(String)
    case other(String)

    init(_ error: Error) {
        if let failure = error as? UpdateFailure {
            self = failure
        } else if error is ReleaseFeed.ParseError {
            self = .unreadable
        } else if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: self = .offline
            case .timedOut: self = .timedOut
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed: self = .unreachable
            default: self = .other(error.localizedDescription)
            }
        } else {
            self = .other(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .offline: "Your Mac seems to be offline."
        case .timedOut: "GitHub didn't answer in time."
        case .unreachable: "Keylog couldn't reach GitHub."
        case .status(404): "GitHub didn't find Keylog's releases (error 404)."
        case .status(403), .status(429): "GitHub is limiting how often Keylog can ask. Try again in an hour."
        case .status(let code): "GitHub answered with error \(code)."
        case .downloadStatus(let code): "GitHub didn't send the update (error \(code))."
        case .unreadable: "GitHub's answer couldn't be read."
        case .incomplete: "The download stopped before it was complete."
        case .damaged: "The download is damaged."
        case .notKeylog: "The download isn't Keylog."
        case .signedDifferently: "The download isn't signed like this copy of Keylog, so it wasn't installed."
        case .notNewer: "The download isn't newer than this Keylog."
        case .couldntReplace(let reason): "Keylog couldn't replace itself. \(reason)"
        case .other(let reason): reason
        }
    }
}

/// Downloads Keylog.dmg, checks the app in it and puts it in place of the running one.
///
/// Every file it makes lives in one temporary folder that goes on every path, and the disk
/// image is always detached. When Keylog can't write where it is, the disk image is moved to
/// Downloads and opened in Finder instead, for the user to drag across.
@MainActor
final class UpdateInstaller {
    struct Options {
        /// Where the disk image goes when Keylog can't replace itself. Downloads when nil.
        var manualFolder: URL?
        /// Debug runs print what they would open instead of opening Finder or the browser.
        var dryOpen = false
        /// Debug runs: the relaunched copy only writes its version to this file and quits.
        var relaunchProbe: URL?
    }

    enum Outcome: Equatable {
        /// The new version is in place of the old one, which is in the Trash (`trashed`).
        case installed(app: URL, trashed: URL?)
        /// Keylog couldn't replace itself; the disk image is open in Finder. Says why and what to do.
        case openedInFinder(String)
    }

    let options: Options
    var onProgress: (Int64, Int64?) -> Void = { _, _ in }
    var onInstalling: () -> Void = {}

    init(options: Options = Options()) { self.options = options }

    func install(_ offer: UpdateOffer, app: URL = Bundle.main.bundleURL) async throws -> Outcome {
        guard let asset = offer.release.dmg else { throw UpdateFailure.unreadable }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Keylog Update \(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var mount: URL?
        defer {
            // A disk image that wouldn't detach keeps its folder, so nothing on it is touched.
            if mount == nil { try? fm.removeItem(at: work) }
        }

        let dmg = work.appendingPathComponent(ReleaseFeed.assetName)
        try await UpdateDownload.run(asset.url, to: dmg, expected: asset.size, progress: onProgress)
        try Task.checkCancellation()
        onInstalling()

        if let reason = Self.whyNotReplaceable(app) {
            let kept = try keepForManualInstall(dmg, version: offer.release.version)
            open(kept)
            return .openedInFinder(reason)
        }

        let mounted = try await Self.attach(dmg, under: work)
        mount = mounted
        do {
            let found = try Self.findApp(in: mounted)
            try await Self.verify(found, current: offer.current)
            let staged = try Self.stage(found, beside: app)
            defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
            if await Self.detach(mounted) { mount = nil }
            let trashed = try Self.swap(app, with: staged)
            return .installed(app: app, trashed: trashed)
        } catch {
            if mount != nil, await Self.detach(mounted) { mount = nil }
            throw error
        }
    }

    /// Opens the new copy once this one has quit. In a debug run, the new copy only prints its version.
    func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits (up to 10 s) for this process to quit, so macOS starts the new copy instead of
        // bringing the old one forward.
        let wait = "i=0; while kill -0 \(getpid()) 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; sleep 1; "
        if let probe = options.relaunchProbe {
            process.arguments = ["-c", wait + #"open --stdout "$1" "$0" --args --version"#, app.path, probe.path]
        } else {
            // --relaunched: the new copy waits for this one to be gone before it starts counting.
            process.arguments = ["-c", wait + #"open "$0" --args --relaunched"#, app.path]
        }
        try process.run()
    }

    // MARK: Steps

    /// Why Keylog can't replace itself where it is, or nil when it can.
    static func whyNotReplaceable(_ app: URL) -> String? {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        let readOnly = (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if app.pathExtension != "app" || app.path.contains("/AppTranslocation/") || readOnly {
            return "Keylog is running from a disk image or a temporary place, so it can't replace itself. The new version is open in Finder: drag Keylog to Applications."
        }
        if !fm.isWritableFile(atPath: folder.path) || !fm.isWritableFile(atPath: app.path) {
            return "Keylog can't write to the folder it's in, so it can't replace itself. The new version is open in Finder: drag Keylog to Applications."
        }
        return nil
    }

    /// Moves the disk image to Downloads, as "Keylog 1.0.3.dmg".
    private func keepForManualInstall(_ dmg: URL, version: SemanticVersion) throws -> URL {
        let fm = FileManager.default
        let folder = options.manualFolder ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent("Keylog \(version).dmg")
        var number = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("Keylog \(version) \(number).dmg")
            number += 1
        }
        try fm.moveItem(at: dmg, to: destination)
        return destination
    }

    private func open(_ url: URL) {
        if options.dryOpen {
            print("would open \(url.path)")
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Mounts the disk image read-only, out of sight (no Finder window, no Desktop icon).
    private static func attach(_ dmg: URL, under folder: URL) async throws -> URL {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                                 ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                  "-mountrandom", folder.path, "-plist", dmg.path])
        } catch {
            NSLog("Keylog: couldn't mount the update: %@", "\(error)")
            throw UpdateFailure.damaged
        }
        let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let path = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else { throw UpdateFailure.damaged }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Detaches the disk image; true when it is gone.
    @discardableResult
    private static func detach(_ mount: URL) async -> Bool {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        if (try? await ProcessRunner.run(hdiutil, ["detach", mount.path, "-quiet"])) != nil { return true }
        if (try? await ProcessRunner.run(hdiutil, ["detach", mount.path, "-force", "-quiet"])) != nil { return true }
        NSLog("Keylog: couldn't detach %@", mount.path)
        return false
    }

    private static func findApp(in mount: URL) throws -> URL {
        let named = mount.appendingPathComponent("Keylog.app")
        if FileManager.default.fileExists(atPath: named.appendingPathComponent("Contents/Info.plist").path) { return named }
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1 else { throw UpdateFailure.notKeylog }
        return apps[0]
    }

    /// The same app (bundle identifier), a newer version, an intact signature, and signed by the
    /// same certificate as the running copy. Input Monitoring belongs to that signature: an update
    /// signed any other way would stop counting, and could be someone else's app.
    private static func verify(_ app: URL, current: SemanticVersion) async throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let identifier = info?["CFBundleIdentifier"] as? String, identifier == Bundle.main.bundleIdentifier else {
            throw UpdateFailure.notKeylog
        }
        guard let text = info?["CFBundleShortVersionString"] as? String, let version = SemanticVersion(text), version > current else {
            throw UpdateFailure.notNewer
        }
        let check = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", app.path],
                                                 allowFailure: true)
        guard check?.status == 0 else {
            NSLog("Keylog: the update's signature doesn't check out: %@", check?.stderr ?? "codesign didn't run")
            throw UpdateFailure.damaged
        }
        guard signedLikeThisCopy(app) else {
            NSLog("Keylog: the update isn't signed with this copy's certificate")
            throw UpdateFailure.signedDifferently
        }
    }

    /// Whether `app` meets the running copy's designated requirement: the same identifier and the
    /// same signing certificate. An ad-hoc copy's requirement is its own hash, which no update meets.
    static func signedLikeThisCopy(_ app: URL, running: URL = Bundle.main.bundleURL) -> Bool {
        var current: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(running as CFURL, [], &current) == errSecSuccess, let current,
              SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { return false }
        return SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    /// Copies the new app to a temporary folder on the same disk as the running one, so the
    /// swap is a rename.
    private static func stage(_ found: URL, beside app: URL) throws -> URL {
        let fm = FileManager.default
        do {
            let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: app.deletingLastPathComponent(), create: true)
            let staged = folder.appendingPathComponent(app.lastPathComponent)
            try fm.copyItem(at: found, to: staged)
            return staged
        } catch {
            throw UpdateFailure.couldntReplace(error.localizedDescription)
        }
    }

    /// Moves the running app to the Trash and the new one into its place. If the second step
    /// fails, the old one comes back.
    private static func swap(_ app: URL, with staged: URL) throws -> URL? {
        let fm = FileManager.default
        var trashed: NSURL?
        do {
            try fm.trashItem(at: app, resultingItemURL: &trashed)
        } catch {
            // Some disks have no Trash: replace in place instead.
            do {
                _ = try fm.replaceItemAt(app, withItemAt: staged)
                return nil
            } catch {
                throw UpdateFailure.couldntReplace(error.localizedDescription)
            }
        }
        do {
            try fm.moveItem(at: staged, to: app)
        } catch {
            if let back = trashed as URL? { try? fm.moveItem(at: back, to: app) }
            throw UpdateFailure.couldntReplace(error.localizedDescription)
        }
        return trashed as URL?
    }
}

/// One download with progress, cancelled with its task.
enum UpdateDownload {
    @MainActor
    static func run(_ url: URL, to destination: URL, expected: Int64,
                    progress: @escaping (Int64, Int64?) -> Void) async throws {
        let total = expected > 0 ? expected : nil
        if url.isFileURL {
            // A local feed, for tests.
            do { try FileManager.default.copyItem(at: url, to: destination) } catch { throw UpdateFailure.incomplete }
        } else {
            let delegate = DownloadDelegate(destination: destination) { received, reported in
                DispatchQueue.main.async { progress(received, total ?? reported) }
            }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                                             timeoutInterval: 60))
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let total, size != total { throw UpdateFailure.incomplete }
        progress(size, total ?? size)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // About 15 times a second is plenty for a bar.
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 1.0 / 15 else { return }
        lastReport = now
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = UpdateFailure.downloadStatus(http.statusCode)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = UpdateFailure.other(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = continuation
        continuation = nil
        if let error = error as? URLError, error.code == .cancelled {
            result?.resume(throwing: CancellationError())
        } else if let error {
            result?.resume(throwing: UpdateFailure(error))
        } else if let failure {
            result?.resume(throwing: failure)
        } else {
            result?.resume()
        }
    }
}

/// Runs a command-line tool and waits for it.
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct Failed: Error {
        let result: Result
    }

    /// Runs `executable` with `arguments`. Cancelling the calling task stops it. Throws `Failed`
    /// when the exit status isn't 0, unless `allowFailure` is set.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], allowFailure: Bool = false) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("keylog-run-\(UUID().uuidString)")
        let err = out.appendingPathExtension("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: err)
        }
        // Files rather than pipes, so a chatty tool can't fill a pipe and stall.
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        let result = Result(status: status,
                            stdout: (try? String(contentsOf: out, encoding: .utf8)) ?? "",
                            stderr: (try? String(contentsOf: err, encoding: .utf8)) ?? "")
        if status != 0 && !allowFailure { throw Failed(result: result) }
        return result
    }
}
