import XCTest
@testable import Ngate2VPNApp

final class AppUpdateInstallerTests: XCTestCase {
    /// Real shape of `hdiutil attach -plist`'s stdout (trimmed to the keys
    /// this code reads).
    private let realisticPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>system-entities</key>
        <array>
            <dict>
                <key>content-hint</key>
                <string>EF57347C-0000-11AA-AA11-00306543ECAC</string>
                <key>dev-entry</key>
                <string>/dev/disk5</string>
            </dict>
            <dict>
                <key>content-hint</key>
                <string>41504653-0000-11AA-AA11-00306543ECAC</string>
                <key>dev-entry</key>
                <string>/dev/disk5s1</string>
                <key>mount-point</key>
                <string>/Volumes/Ngate2VPN 4.10</string>
                <key>volume-kind</key>
                <string>apfs</string>
            </dict>
        </array>
    </dict>
    </plist>
    """.data(using: .utf8)!

    func testParsesMountPointFromRealisticPlist() {
        let mountPoint = AppUpdateInstaller.parseMountPoint(from: realisticPlist)
        XCTAssertEqual(mountPoint, URL(fileURLWithPath: "/Volumes/Ngate2VPN 4.10"))
    }

    /// Regression: `hdiutil attach -plist -quiet` silently emits zero bytes
    /// on stdout instead of the plist (confirmed empirically) -- parsing
    /// empty data must fail cleanly (nil), not crash.
    func testEmptyDataReturnsNil() {
        XCTAssertNil(AppUpdateInstaller.parseMountPoint(from: Data()))
    }

    func testMalformedPlistReturnsNil() {
        XCTAssertNil(AppUpdateInstaller.parseMountPoint(from: "not a plist".data(using: .utf8)!))
    }

    func testPlistWithNoMountPointKeyReturnsNil() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict><key>dev-entry</key><string>/dev/disk5</string></dict>
            </array>
        </dict>
        </plist>
        """.data(using: .utf8)!
        XCTAssertNil(AppUpdateInstaller.parseMountPoint(from: plist))
    }
}
