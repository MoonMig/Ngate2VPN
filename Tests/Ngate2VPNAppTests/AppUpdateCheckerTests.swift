import XCTest
@testable import Ngate2VPNApp

final class AppUpdateCheckerTests: XCTestCase {
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

    func testAvailabilityWrapsComparisonWithRelease() {
        let newer = AppUpdateChecker.GitHubRelease(tagName: "v4.05", htmlURL: URL(string: "https://example.com/4.05")!)
        guard case .available(let version, let url) = AppUpdateChecker.availability(for: newer, currentVersion: "4.04") else {
            return XCTFail("expected .available")
        }
        XCTAssertEqual(version, "v4.05")
        XCTAssertEqual(url, newer.htmlURL)

        let older = AppUpdateChecker.GitHubRelease(tagName: "v4.03", htmlURL: URL(string: "https://example.com/4.03")!)
        XCTAssertEqual(AppUpdateChecker.availability(for: older, currentVersion: "4.04"), .upToDate)

        let same = AppUpdateChecker.GitHubRelease(tagName: "v4.04", htmlURL: URL(string: "https://example.com/4.04")!)
        XCTAssertEqual(AppUpdateChecker.availability(for: same, currentVersion: "4.04"), .upToDate)
    }

    func testGitHubReleaseDecodesExpectedFields() throws {
        let json = """
        {"tag_name":"v4.04","html_url":"https://github.com/MoonMig/Ngate2VPN/releases/tag/v4.04","body":"notes","other_field":123}
        """.data(using: .utf8)!
        let release = try JSONDecoder().decode(AppUpdateChecker.GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v4.04")
        XCTAssertEqual(release.htmlURL, URL(string: "https://github.com/MoonMig/Ngate2VPN/releases/tag/v4.04")!)
    }
}
