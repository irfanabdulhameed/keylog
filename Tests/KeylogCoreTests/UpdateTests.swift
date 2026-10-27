import Foundation
import Testing
@testable import KeylogCore

struct UpdateTests {
    // MARK: Versions

    @Test func readsVersions() {
        #expect(SemanticVersion("1.0.3") == SemanticVersion(1, 0, 3))
        #expect(SemanticVersion("v1.0.3") == SemanticVersion(1, 0, 3))
        #expect(SemanticVersion("V2") == SemanticVersion(2, 0, 0))
        #expect(SemanticVersion("1.2") == SemanticVersion(1, 2, 0))
        #expect(SemanticVersion(" 1.0.0 ")?.description == "1.0.0")
        #expect(SemanticVersion("1.1.0-beta.1")?.prerelease == "beta.1")
        #expect(SemanticVersion("1.0.0+20261022") == SemanticVersion(1, 0, 0))
        for bad in ["", "v", "1.", "1..2", "1.2.3.4", "one", "1.x", "-1.0", "1.0-", "latest"] {
            #expect(SemanticVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func comparesVersionsAsNumbers() {
        func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }
        #expect(v("1.0.10") > v("1.0.9"))
        #expect(v("1.10.0") > v("1.9.9"))
        #expect(v("2.0.0") > v("1.99.99"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(!(v("1.0.0") < v("1.0.0")))
        #expect(v("1.1.0-beta") < v("1.1.0"))
        #expect(v("1.1.0-beta.2") < v("1.1.0-beta.10"))
        #expect(v("1.1.0-beta") > v("1.0.9"))
        #expect([v("1.0.2"), v("1.0.10"), v("1.0.1")].sorted() == [v("1.0.1"), v("1.0.2"), v("1.0.10")])
    }

    // MARK: The feed

    static let feed = """
    [
      {
        "tag_name": "v1.0.4", "name": "Keylog 1.0.4", "draft": true, "prerelease": false,
        "body": "- Not finished", "published_at": null, "html_url": "https://github.com/irfanabdulhameed/keylog/releases/tag/untagged-1",
        "assets": [{"name": "Keylog.dmg", "size": 1, "browser_download_url": "https://example.com/draft/Keylog.dmg"}]
      },
      {
        "tag_name": "v1.1.0-beta.1", "name": "Keylog 1.1 beta", "draft": false, "prerelease": true,
        "body": "- Trying something", "published_at": "2026-10-21T08:00:00Z",
        "assets": [{"name": "Keylog.dmg", "size": 2, "browser_download_url": "https://example.com/beta/Keylog.dmg"}]
      },
      {
        "tag_name": "v1.0.3", "name": "Keylog 1.0.3", "draft": false, "prerelease": false,
        "body": "## Fixes\\r\\n- The widget opens on the right display\\r\\n- **Faster** HEIC to JPG",
        "published_at": "2026-10-22T09:30:00Z", "html_url": "https://github.com/irfanabdulhameed/keylog/releases/tag/v1.0.3",
        "assets": [
          {"name": "Keylog.dmg.sha256", "size": 64, "browser_download_url": "https://example.com/v1.0.3/Keylog.dmg.sha256"},
          {"name": "Keylog.dmg", "size": 18000000, "browser_download_url": "https://github.com/irfanabdulhameed/keylog/releases/download/v1.0.3/Keylog.dmg"}
        ]
      },
      {"tag_name": "nightly", "draft": false, "prerelease": false, "assets": []},
      {"name": "no tag at all"},
      {
        "tag_name": "v1.0.2", "draft": false, "prerelease": false, "body": "- Copy button on the result pill",
        "published_at": "2026-10-14T12:00:00Z",
        "assets": [{"name": "Keylog.dmg", "size": 17900000, "browser_download_url": "https://example.com/v1.0.2/Keylog.dmg"}]
      },
      {
        "tag_name": "v1.0.1", "draft": false, "prerelease": false, "body": "- First fixes", "published_at": "2026-10-10T12:00:00Z",
        "assets": [{"name": "Keylog.dmg", "size": 17800000, "browser_download_url": "https://example.com/v1.0.1/Keylog.dmg"}]
      }
    ]
    """

    @Test func parsesGitHubReleases() throws {
        let releases = try ReleaseFeed.parse(Data(Self.feed.utf8))
        #expect(releases.map(\.tag) == ["v1.0.4", "v1.1.0-beta.1", "v1.0.3", "v1.0.2", "v1.0.1"])

        let latest = releases[2]
        #expect(latest.version == SemanticVersion(1, 0, 3))
        #expect(latest.name == "Keylog 1.0.3")
        #expect(latest.notes.hasPrefix("## Fixes"))
        #expect(latest.published == Date(timeIntervalSince1970: 1_792_661_400))
        #expect(latest.page?.absoluteString == "https://github.com/irfanabdulhameed/keylog/releases/tag/v1.0.3")
        #expect(latest.dmg?.name == "Keylog.dmg")
        #expect(latest.dmg?.size == 18_000_000)
        #expect(latest.dmg?.url.absoluteString == "https://github.com/irfanabdulhameed/keylog/releases/download/v1.0.3/Keylog.dmg")
        #expect(latest.isStable)

        #expect(releases[0].isDraft && !releases[0].isStable && releases[0].published == nil)
        #expect(releases[1].isPrerelease && !releases[1].isStable)
        #expect(releases[3].page == nil && releases[3].name == "")
    }

    @Test func refusesWhatIsNotAList() {
        #expect(throws: ReleaseFeed.ParseError.notAList) {
            try ReleaseFeed.parse(Data(#"{"message": "Not Found", "status": "404"}"#.utf8))
        }
        #expect(throws: ReleaseFeed.ParseError.notAList) { try ReleaseFeed.parse(Data("<html>".utf8)) }
        #expect((try? ReleaseFeed.parse(Data("[]".utf8)))?.isEmpty == true)
    }

    // MARK: Choosing

    @Test func offersTheNewestOrdinaryRelease() throws {
        let releases = try ReleaseFeed.parse(Data(Self.feed.utf8))
        let offer = try #require(Updates.offer(releases, current: SemanticVersion(1, 0, 1)))
        // Not the draft (1.0.4) and not the beta (1.1.0).
        #expect(offer.release.version == SemanticVersion(1, 0, 3))
        #expect(offer.current == SemanticVersion(1, 0, 1))
        // Every release since 1.0.1, newest first; 1.0.1 itself is what's running.
        #expect(offer.releases.map(\.version.description) == ["1.0.3", "1.0.2"])
        #expect(UpdateText.available(offer) == "Keylog 1.0.3 is available. You have 1.0.1.")
    }

    @Test func upToDateMeansNoOffer() throws {
        let releases = try ReleaseFeed.parse(Data(Self.feed.utf8))
        #expect(Updates.offer(releases, current: SemanticVersion(1, 0, 3)) == nil)
        // A build newer than anything released, such as one being worked on.
        #expect(Updates.offer(releases, current: SemanticVersion(1, 2, 0)) == nil)
        #expect(Updates.offer([], current: SemanticVersion(1, 0, 0)) == nil)
    }

    @Test func skippedVersionsAllShowTheirNotes() throws {
        let releases = try ReleaseFeed.parse(Data(Self.feed.utf8))
        let offer = try #require(Updates.offer(releases, current: SemanticVersion(1, 0, 0)))
        #expect(offer.releases.map(\.version.description) == ["1.0.3", "1.0.2", "1.0.1"])
    }

    @Test func aReleaseWithoutItsDiskImageWaits() {
        let dmg = ReleaseAsset(name: "Keylog.dmg", url: URL(string: "https://example.com/Keylog.dmg")!, size: 10)
        let releases = [
            Release(tag: "v1.0.5", version: SemanticVersion(1, 0, 5)),
            Release(tag: "v1.0.4", version: SemanticVersion(1, 0, 4), dmg: dmg),
            Release(tag: "v1.0.3", version: SemanticVersion(1, 0, 3), dmg: dmg),
        ]
        let offer = Updates.offer(releases, current: SemanticVersion(1, 0, 2))
        #expect(offer?.release.version == SemanticVersion(1, 0, 4))
        #expect(offer?.releases.map(\.tag) == ["v1.0.4", "v1.0.3"])
        // Only the release still being made is newer: nothing to install yet.
        #expect(Updates.offer(releases, current: SemanticVersion(1, 0, 4)) == nil)
    }

    @Test func orderAndDuplicatesDontMatter() {
        let dmg = ReleaseAsset(name: "Keylog.dmg", url: URL(string: "https://example.com/Keylog.dmg")!, size: 10)
        let releases = [
            Release(tag: "v1.0.9", version: SemanticVersion(1, 0, 9), notes: "- nine", dmg: dmg),
            Release(tag: "v1.0.10", version: SemanticVersion(1, 0, 10), notes: "- ten", dmg: dmg),
            Release(tag: "1.0.10", version: SemanticVersion(1, 0, 10), notes: "- ten again", dmg: dmg),
        ]
        let offer = Updates.offer(releases, current: SemanticVersion(1, 0, 8))
        #expect(offer?.release.notes == "- ten")
        #expect(offer?.releases.map(\.notes) == ["- ten", "- nine"])
    }

    // MARK: Notes

    @Test func notesBecomeLines() {
        let notes = """
        <!-- Made by scripts/release.sh -->
        ## What's new

        - Convert **HEIC** to JPG faster
        * The result pill shows how much smaller the file got,
          and the new size
        + Fixed: `cwebp` was found only in /usr/local
          - nested under it
        1. Numbered items count too
        2) And this kind
        - [x] A task list item

        A plain line of text.
        ---
        ```
        code fences are left out
        ```
        **Full Changelog**: https://github.com/irfanabdulhameed/keylog/compare/v1.0.2...v1.0.3
        #NotAHeading
        """
        let lines = ReleaseNotes.lines(notes)
        #expect(lines == [
            NoteLine(.heading, "What's new"),
            NoteLine(.item(level: 0), "Convert **HEIC** to JPG faster"),
            NoteLine(.item(level: 0), "The result pill shows how much smaller the file got, and the new size"),
            NoteLine(.item(level: 0), "Fixed: `cwebp` was found only in /usr/local"),
            NoteLine(.item(level: 1), "nested under it"),
            NoteLine(.item(level: 0), "Numbered items count too"),
            NoteLine(.item(level: 0), "And this kind"),
            NoteLine(.item(level: 0), "A task list item"),
            NoteLine(.item(level: 0), "A plain line of text."),
            NoteLine(.item(level: 0), "code fences are left out"),
            NoteLine(.item(level: 0), "#NotAHeading"),
        ])
    }

    @Test func notesEdgeCases() {
        #expect(ReleaseNotes.lines("").isEmpty)
        #expect(ReleaseNotes.lines("\n\n  \n").isEmpty)
        #expect(ReleaseNotes.lines("<!--\nhidden\n-->\n- shown") == [NoteLine(.item(level: 0), "shown")])
        #expect(ReleaseNotes.lines("- a <!-- note --> b") == [NoteLine(.item(level: 0), "a  b")])
        #expect(ReleaseNotes.lines("### Fixes ###") == [NoteLine(.heading, "Fixes")])
        #expect(ReleaseNotes.lines("-\n- \n* ") .isEmpty)
        #expect(ReleaseNotes.lines("-not a list") == [NoteLine(.item(level: 0), "-not a list")])
    }

    // MARK: Words and timing

    @Test func progressText() {
        let en = Locale(identifier: "en_US")
        #expect(UpdateText.progress(received: 12_400_000, total: 18_000_000, locale: en) == "12.4 of 18.0 MB")
        #expect(UpdateText.progress(received: 0, total: 18_000_000, locale: en) == "0.0 of 18.0 MB")
        #expect(UpdateText.progress(received: 19_000_000, total: 18_000_000, locale: en) == "18.0 of 18.0 MB")
        #expect(UpdateText.progress(received: 5_260_000, total: nil, locale: en) == "5.3 MB")
        #expect(UpdateText.progress(received: 5_200_000, total: 0, locale: en) == "5.2 MB")
        #expect(UpdateText.progress(received: 1_500_000, total: 2_000_000_000, locale: en) == "1.5 of 2,000.0 MB")
        #expect(UpdateText.progress(received: 12_400_000, total: 18_000_000, locale: Locale(identifier: "de_DE")) == "12,4 of 18,0 MB")
    }

    @Test func onlyFreeNetworks() {
        #expect(UpdatePolicy.networkAllows(satisfied: true, expensive: false, constrained: false))
        #expect(!UpdatePolicy.networkAllows(satisfied: true, expensive: true, constrained: false), "a phone's hotspot")
        #expect(!UpdatePolicy.networkAllows(satisfied: true, expensive: false, constrained: true), "Low Data Mode")
        #expect(!UpdatePolicy.networkAllows(satisfied: false, expensive: false, constrained: false), "offline")
    }

    @Test func whenToCheck() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdatePolicy.launchDelay == 10 && UpdatePolicy.interval == 6 * 3600 && UpdatePolicy.snooze == 24 * 3600)
        for reason in [UpdatePolicy.Reason.network, .wake] {
            #expect(UpdatePolicy.shouldCheck(reason, lastCheck: nil, now: now))
            #expect(!UpdatePolicy.shouldCheck(reason, lastCheck: now.addingTimeInterval(-60), now: now))
            #expect(UpdatePolicy.shouldCheck(reason, lastCheck: now.addingTimeInterval(-UpdatePolicy.minimumGap), now: now))
        }
        #expect(UpdatePolicy.shouldCheck(.launch, lastCheck: now, now: now))
        #expect(UpdatePolicy.shouldCheck(.timer, lastCheck: now.addingTimeInterval(-60), now: now))
    }

    @Test func laterWaitsADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdatePolicy.mayOffer(snoozedUntil: nil, now: now))
        let until = now.addingTimeInterval(UpdatePolicy.snooze)
        #expect(!UpdatePolicy.mayOffer(snoozedUntil: until, now: now.addingTimeInterval(23 * 3600)))
        #expect(UpdatePolicy.mayOffer(snoozedUntil: until, now: until))
    }
}
