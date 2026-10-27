import Foundation

// What the updater decides, kept apart from the network and the windows so it can be tested:
// reading GitHub's list of releases, comparing versions, choosing the release to offer, the
// notes to show with it, and when to check.

/// A version like 1.0.3: major, minor and patch, compared as numbers, so 1.0.10 is newer than 1.0.9.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// The part after a hyphen, as in 1.1.0-beta.1. Empty for an ordinary release.
    public var prerelease: String

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0, prerelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Reads "1.0.3", "v1.0.3", "1.2" (1.2.0) or "1.1.0-beta.1". Build metadata after a plus is
    /// ignored. nil for anything that isn't a version.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var prerelease = ""
        if let hyphen = rest.firstIndex(of: "-") {
            prerelease = String(rest[rest.index(after: hyphen)...])
            rest = rest[..<hyphen]
            if prerelease.isEmpty { return nil }
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// A pre-release comes before its release: 1.1.0-beta < 1.1.0.
    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        return a.prerelease.compare(b.prerelease, options: .numeric) == .orderedAscending
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-\(prerelease)")
    }
}

/// A file attached to a release.
public struct ReleaseAsset: Equatable, Sendable {
    public var name: String
    public var url: URL
    public var size: Int64

    public init(name: String, url: URL, size: Int64) {
        self.name = name
        self.url = url
        self.size = size
    }
}

/// One release from GitHub's list.
public struct Release: Equatable, Sendable {
    public var tag: String
    public var version: SemanticVersion
    public var name: String
    /// The release notes, in Markdown.
    public var notes: String
    public var published: Date?
    public var isDraft: Bool
    public var isPrerelease: Bool
    /// The release's page on GitHub, for downloading by hand.
    public var page: URL?
    /// Keylog.dmg, when it is attached.
    public var dmg: ReleaseAsset?

    public init(tag: String, version: SemanticVersion, name: String = "", notes: String = "", published: Date? = nil,
                isDraft: Bool = false, isPrerelease: Bool = false, page: URL? = nil, dmg: ReleaseAsset? = nil) {
        self.tag = tag
        self.version = version
        self.name = name
        self.notes = notes
        self.published = published
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.page = page
        self.dmg = dmg
    }

    /// An ordinary release, the only kind Keylog offers: not a draft and not a pre-release.
    public var isStable: Bool { !isDraft && !isPrerelease && !version.isPrerelease }
}

/// GitHub's list of Keylog releases.
public enum ReleaseFeed {
    /// The disk image every release carries. Its name never changes, so
    /// releases/latest/download/Keylog.dmg always points at the newest one.
    public static let assetName = "Keylog.dmg"
    public static let defaultURL = URL(string: "https://api.github.com/repos/irfanabdulhameed/keylog/releases?per_page=20")!

    public enum ParseError: Error, Equatable {
        /// The answer isn't a list of releases (GitHub answers errors with an object).
        case notAList
    }

    /// Reads the JSON GitHub answers `GET /repos/{owner}/{repo}/releases` with. A release that
    /// can't be read, or whose tag isn't a version, is left out rather than failing the list.
    public static func parse(_ data: Data) throws -> [Release] {
        let entries: [Lossy<Entry>]
        do {
            entries = try JSONDecoder().decode([Lossy<Entry>].self, from: data)
        } catch {
            throw ParseError.notAList
        }
        return entries.compactMap { $0.value?.release }
    }

    private struct Entry: Decodable {
        var tag_name: String
        var name: String?
        var body: String?
        var draft: Bool?
        var prerelease: Bool?
        var published_at: String?
        var html_url: String?
        var assets: [Lossy<Asset>]?

        var release: Release? {
            guard let version = SemanticVersion(tag_name) else { return nil }
            let dmg = (assets ?? []).compactMap(\.value).first { $0.name == ReleaseFeed.assetName }
            return Release(
                tag: tag_name, version: version, name: name ?? "", notes: body ?? "",
                published: published_at.flatMap { try? Date($0, strategy: .iso8601) },
                isDraft: draft ?? false, isPrerelease: prerelease ?? false,
                page: html_url.flatMap(URL.init(string:)),
                dmg: dmg.flatMap { asset in
                    URL(string: asset.browser_download_url).map { ReleaseAsset(name: asset.name, url: $0, size: asset.size ?? 0) }
                })
        }
    }

    private struct Asset: Decodable {
        var name: String
        var size: Int64?
        var browser_download_url: String
    }

    /// Decodes a value, or nil when it doesn't fit, so one odd entry doesn't spoil the list.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

/// What the update window offers: the release to install, and every release since the one running.
public struct UpdateOffer: Equatable, Sendable {
    /// The version running now.
    public var current: SemanticVersion
    /// The newest release, the one Update Now installs.
    public var release: Release
    /// Every release newer than `current`, up to and including `release`, newest first, so
    /// someone who skipped versions sees all that changed.
    public var releases: [Release]

    public init(current: SemanticVersion, release: Release, releases: [Release]) {
        self.current = current
        self.release = release
        self.releases = releases
    }
}

public enum Updates {
    /// The newest ordinary release newer than `current` that carries Keylog.dmg, with the notes of
    /// every ordinary release since `current`. Drafts and pre-releases are never offered. nil when
    /// Keylog is up to date.
    public static func offer(_ releases: [Release], current: SemanticVersion) -> UpdateOffer? {
        var seen = Set<SemanticVersion>()
        let newer = releases
            .filter { $0.isStable && $0.version > current }
            .sorted { $0.version > $1.version }
            .filter { seen.insert($0.version).inserted }
        // A release still being made has no disk image yet: offer the newest one that has.
        guard let index = newer.firstIndex(where: { $0.dmg != nil }) else { return nil }
        return UpdateOffer(current: current, release: newer[index], releases: Array(newer[index...]))
    }
}

/// One line of release notes, ready to show.
public struct NoteLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A Markdown heading.
        case heading
        /// A list item, or a plain line of text. `level` is 1 for an item nested under another.
        case item(level: Int)
    }

    public var kind: Kind
    /// The line's text, still with inline Markdown (bold, code, links).
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum ReleaseNotes {
    /// Turns release notes in Markdown into lines: headings, and items for the list. Plain lines
    /// become items too. Blank lines, rules, code fences, HTML comments and GitHub's "Full
    /// Changelog" link are left out; a line that continues a list item joins it.
    public static func lines(_ markdown: String) -> [NoteLine] {
        var lines: [NoteLine] = []
        var inComment = false
        var lastWasItem = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if inComment {
                guard let end = line.range(of: "-->") else { continue }
                line = String(line[end.upperBound...])
                inComment = false
            }
            while let start = line.range(of: "<!--") {
                if let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line = String(line[..<start.lowerBound])
                    inComment = true
                }
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let text = line.trimmingCharacters(in: .whitespaces)
            // An empty list item is only its mark.
            if text.isEmpty || text == "-" || text == "*" || text == "+" || text.hasPrefix("```") || text.hasPrefix("~~~") || isRule(text)
                || text.lowercased().hasPrefix("**full changelog**") {
                lastWasItem = false
                continue
            }
            if let heading = heading(text) {
                lines.append(NoteLine(.heading, heading))
                lastWasItem = false
            } else if let item = item(text) {
                lines.append(NoteLine(.item(level: indent >= 2 ? 1 : 0), item))
                lastWasItem = true
            } else if lastWasItem && indent >= 2, let last = lines.indices.last {
                lines[last].text += " " + text
            } else {
                lines.append(NoteLine(.item(level: 0), text))
                lastWasItem = false
            }
        }
        return lines
    }

    private static func heading(_ text: String) -> String? {
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = text.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func item(_ text: String) -> String? {
        var rest: Substring
        if let first = text.first, "-*+".contains(first), text.dropFirst().first == " " {
            rest = text.dropFirst(2)
        } else {
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            let after = text.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count < 4, let mark = after.first, mark == "." || mark == ")",
                  after.dropFirst().first == " " else { return nil }
            rest = after.dropFirst(2)
        }
        // A task list's box says nothing in release notes.
        for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) { rest = rest.dropFirst(box.count) }
        let item = rest.trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    private static func isRule(_ text: String) -> Bool {
        let marks = text.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }
}

/// The updater's words, where they depend on numbers.
public enum UpdateText {
    /// "Keylog 1.0.3 is available. You have 1.0.1."
    public static func available(_ offer: UpdateOffer) -> String {
        "Keylog \(offer.release.version) is available. You have \(offer.current)."
    }

    /// "12.4 of 18.0 MB", in decimal megabytes like Finder. Just "12.4 MB" when the size isn't known.
    public static func progress(received: Int64, total: Int64?, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(1)).grouping(.automatic)
        func megabytes(_ bytes: Int64) -> String { (Double(max(bytes, 0)) / 1_000_000).formatted(style) }
        guard let total, total > 0 else { return "\(megabytes(received)) MB" }
        return "\(megabytes(min(received, total))) of \(megabytes(total)) MB"
    }
}

/// When Keylog checks for a new version.
public enum UpdatePolicy {
    /// The first check, this long after Keylog starts.
    public static let launchDelay: TimeInterval = 10
    /// Then every 6 hours.
    public static let interval: TimeInterval = 6 * 3600
    /// A network coming back or the Mac waking checks again, but not within this long of the last check.
    public static let minimumGap: TimeInterval = 15 * 60
    /// Later hides the window this long, or until Keylog starts again.
    public static let snooze: TimeInterval = 24 * 3600

    public enum Reason: String, Sendable {
        case launch, timer, network, wake
    }

    /// Only on a network that costs nothing: Wi-Fi or Ethernet. Not a phone's hotspot (expensive)
    /// and not with Low Data Mode on (constrained).
    public static func networkAllows(satisfied: Bool, expensive: Bool, constrained: Bool) -> Bool {
        satisfied && !expensive && !constrained
    }

    /// Launch and the timer always check. A network coming back or a wake checks only when the
    /// last check was a while ago, so a flaky network doesn't check over and over.
    public static func shouldCheck(_ reason: Reason, lastCheck: Date?, now: Date) -> Bool {
        switch reason {
        case .launch, .timer: true
        case .network, .wake: lastCheck.map { now.timeIntervalSince($0) >= minimumGap } ?? true
        }
    }

    /// Whether an automatic check may show the window. Later sets `snoozedUntil`; a new launch
    /// starts with none.
    public static func mayOffer(snoozedUntil: Date?, now: Date) -> Bool {
        snoozedUntil.map { now >= $0 } ?? true
    }
}
