import Foundation
import AppKit
import Security

/// Installs a downloaded update DMG in place and relaunches the app. Unlike
/// `AppUpdateChecker` (pure comparison + one network call), this does real,
/// hard-to-undo work: mounts a disk image, verifies the app inside it, and
/// replaces the running bundle on disk. Every step must leave the
/// currently-installed app untouched on failure — a half-applied update must
/// never happen, and this must never run an app we can't vouch for.
enum AppUpdateInstaller {
    enum InstallError: Error, CustomStringConvertible {
        case mountFailed(String)
        case appNotFoundInImage
        case signatureMismatch
        case replaceFailed(String)

        var description: String {
            switch self {
            case .mountFailed(let detail): return "Could not open the disk image: \(detail)"
            case .appNotFoundInImage: return "No app found in the downloaded disk image"
            case .signatureMismatch: return "The downloaded app is not signed by the same identity as this app — refusing to install it"
            case .replaceFailed(let detail): return "Could not replace the app: \(detail)"
            }
        }
    }

    /// Mounts `dmgPath`, finds the `.app` inside, verifies it is signed by
    /// the SAME identity as the currently running app (never trust a
    /// download on provenance alone — this is the one thing standing between
    /// a compromised GitHub release and this app silently replacing itself
    /// with whatever showed up there), replaces the running bundle with it,
    /// launches the new copy, and asks AppKit to terminate the current
    /// process through its normal quit handshake (`applicationShouldTerminate`),
    /// so tunnels and DNS routes are torn down cleanly instead of killed.
    @MainActor
    static func installAndRelaunch(dmgPath: URL) async throws {
        let mountPoint = try mount(dmgPath)
        defer { unmount(mountPoint) }

        guard let appInImage = findApp(in: mountPoint) else {
            throw InstallError.appNotFoundInImage
        }
        guard verifySameSigner(appInImage) else {
            throw InstallError.signatureMismatch
        }

        // The mounted image is read-only; stage a local copy before handing
        // it to FileManager's replace API, which may want to consume its source.
        let stagedCopy = FileManager.default.temporaryDirectory.appendingPathComponent(appInImage.lastPathComponent)
        try? FileManager.default.removeItem(at: stagedCopy)
        do {
            try FileManager.default.copyItem(at: appInImage, to: stagedCopy)
        } catch {
            throw InstallError.replaceFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: stagedCopy) }

        let runningAppURL = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(runningAppURL, withItemAt: stagedCopy)
        } catch {
            throw InstallError.replaceFailed(error.localizedDescription)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: runningAppURL, configuration: config)
        NSApp.terminate(nil)
    }

    private static func mount(_ dmgPath: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        // No `-quiet` here: combined with `-plist` it suppresses the plist
        // output entirely (confirmed empirically — hdiutil then exits 0 with
        // zero bytes on stdout), which is exactly the mount point info this
        // function exists to read. `-plist` mode is already the non-verbose,
        // machine-readable form, so `-quiet` was redundant even before this
        // was found to be actively harmful.
        process.arguments = ["attach", "-nobrowse", "-plist", dmgPath.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        do {
            try process.run()
        } catch {
            throw InstallError.mountFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw InstallError.mountFailed("hdiutil exited with status \(process.terminationStatus)")
        }
        guard let mountPoint = parseMountPoint(from: data) else {
            throw InstallError.mountFailed("could not parse hdiutil output")
        }
        return mountPoint
    }

    /// Pure: extracts the mount point from `hdiutil attach -plist`'s stdout.
    /// Separated out so the parsing itself — the thing that actually broke
    /// once, when an extra `-quiet` flag silently zeroed out this output —
    /// is unit-testable without shelling out to real hdiutil.
    static func parseMountPoint(from plistData: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            return nil
        }
        return URL(fileURLWithPath: mountPoint)
    }

    private static func unmount(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    private static func findApp(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    /// True if `appURL` satisfies the *running* app's own designated
    /// requirement — i.e. it is signed by the same certificate, not merely
    /// "signed by something." `setup-signing-identity.sh` / `build-app.sh`
    /// pin this to the certificate leaf (not the cdhash), so every release
    /// built with the same local signing identity passes.
    private static func verifySameSigner(_ appURL: URL) -> Bool {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let selfCode else { return false }
        // SecCode is a subtype of SecStaticCode at the CoreFoundation level,
        // but the Swift overlay doesn't model that inheritance — bitcast is
        // the standard way to call a SecStaticCode API with a SecCode.
        let selfStaticCode = unsafeBitCast(selfCode, to: SecStaticCode.self)
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStaticCode, SecCSFlags(), &requirement) == errSecSuccess, let requirement else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }
}
