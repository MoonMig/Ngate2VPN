import XCTest
@testable import Ngate2VPNApp

final class AppUpdateCheckerTests: XCTestCase {
    private func release(tag: String, assets: [AppUpdateChecker.GitHubRelease.Asset] = []) -> AppUpdateChecker.GitHubRelease {
        AppUpdateChecker.GitHubRelease(
            tagName: tag,
            htmlURL: URL(string: "https://example.com/\(tag)")!,
            assets: assets
        )
    }

    private func asset(_ name: String) -> AppUpdateChecker.GitHubRelease.Asset {
        AppUpdateChecker.GitHubRelease.Asset(name: name, downloadURL: URL(string: "https://example.com/\(name)")!)
    }

    func testVersionComponentsStripsLeadingVAndIgnoresSuffix() {
        XCTAssertEqual(AppUpdateChecker.versionComponents("v4.10"), [4, 10])
        XCTAssertEqual(AppUpdateChecker.versionComponents("4.10"), [4, 10])
        XCTAssertEqual(AppUpdateChecker.versionComponents("V4.10-beta"), [4, 10])
        XCTAssertEqual(AppUpdateChecker.versionComponents("4"), [4])
    }

    func testIsNewerComparesNumericallyNotLexicographically() {
        // A naive string compare would say "4.9" > "4.10".
        XCTAssertTrue(AppUpdateChecker.isNewer("v4.10", than: "4.9"))
        XCTAssertFalse(AppUpdateChecker.isNewer("4.9", than: "v4.10"))
    }

    func testIsNewerHandlesDifferentComponentCounts() {
        XCTAssertTrue(AppUpdateChecker.isNewer("4.10.1", than: "4.10"))
        XCTAssertFalse(AppUpdateChecker.isNewer("4.10", than: "4.10.0"))
        XCTAssertFalse(AppUpdateChecker.isNewer("4.10", than: "4.10"))
    }

    func testIsNewerFalseWhenEqualOrOlder() {
        XCTAssertFalse(AppUpdateChecker.isNewer("4.04", than: "4.04"))
        XCTAssertFalse(AppUpdateChecker.isNewer("4.03", than: "4.04"))
    }

    func testAvailabilityWrapsComparisonWithReleaseAndCarriesDownloadURL() {
        let newer = release(tag: "v4.05", assets: [asset("Ngate2VPN-4.05.dmg")])
        guard case .available(let version, let releaseURL, let downloadURL) =
            AppUpdateChecker.availability(for: newer, currentVersion: "4.04") else {
            return XCTFail("expected .available")
        }
        XCTAssertEqual(version, "v4.05")
        XCTAssertEqual(releaseURL, newer.htmlURL)
        XCTAssertEqual(downloadURL, newer.assets[0].downloadURL)

        let older = release(tag: "v4.03")
        XCTAssertEqual(AppUpdateChecker.availability(for: older, currentVersion: "4.04"), .upToDate)

        let same = release(tag: "v4.04")
        XCTAssertEqual(AppUpdateChecker.availability(for: same, currentVersion: "4.04"), .upToDate)
    }

    func testAvailabilityHasNilDownloadURLWhenReleaseHasNoDmgAsset() {
        let newer = release(tag: "v4.05", assets: [asset("notes.txt")])
        guard case .available(_, _, let downloadURL) = AppUpdateChecker.availability(for: newer, currentVersion: "4.04") else {
            return XCTFail("expected .available")
        }
        XCTAssertNil(downloadURL)
    }

    func testDmgAssetPicksDmgByExtensionCaseInsensitively() {
        let r = release(tag: "v4.05", assets: [asset("README.txt"), asset("Ngate2VPN-4.05.DMG")])
        XCTAssertEqual(AppUpdateChecker.dmgAsset(in: r)?.name, "Ngate2VPN-4.05.DMG")
    }

    func testDmgAssetNilWhenNoneMatches() {
        let r = release(tag: "v4.05", assets: [asset("README.txt")])
        XCTAssertNil(AppUpdateChecker.dmgAsset(in: r))
    }

    func testGitHubReleaseDecodesExpectedFieldsIncludingAssets() throws {
        let json = """
        {"tag_name":"v4.04","html_url":"https://github.com/MoonMig/Ngate2VPN/releases/tag/v4.04","body":"notes","other_field":123,
         "assets":[{"name":"Ngate2VPN-4.04.dmg","browser_download_url":"https://github.com/MoonMig/Ngate2VPN/releases/download/v4.04/Ngate2VPN-4.04.dmg","other":1}]}
        """.data(using: .utf8)!
        let release = try JSONDecoder().decode(AppUpdateChecker.GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v4.04")
        XCTAssertEqual(release.htmlURL, URL(string: "https://github.com/MoonMig/Ngate2VPN/releases/tag/v4.04")!)
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].name, "Ngate2VPN-4.04.dmg")
        XCTAssertEqual(release.assets[0].downloadURL, URL(string: "https://github.com/MoonMig/Ngate2VPN/releases/download/v4.04/Ngate2VPN-4.04.dmg")!)
    }
}
