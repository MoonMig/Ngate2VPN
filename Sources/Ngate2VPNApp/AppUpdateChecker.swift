import Foundation

/// Checks GitHub Releases for a newer version and, if the user asks for it,
/// downloads the release DMG into ~/Downloads and reveals it in Finder. The
/// app has no Developer ID or notarization, so it never *installs* anything
/// itself — the user still drags the app to /Applications and clears
/// Gatekeeper once, exactly as with a manual browser download (the
/// downloaded file is flagged quarantined for the same reason, see
/// `markAsQuarantinedDownload`).
enum AppUpdateChecker {
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/MoonMig/Ngate2VPN/releases/latest")!

    /// The fields we need from GitHub's Releases API response.
    struct GitHubRelease: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let downloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    enum Availability: Equatable {
        case upToDate
        case available(version: String, releaseURL: URL, downloadURL: URL?)
    }

    enum CheckError: Error, Equatable, CustomStringConvertible {
        case network(String)
        case malformedResponse

        var description: String {
            switch self {
            case .network(let detail): return detail
            case .malformedResponse: return "Unexpected response from GitHub"
            }
        }
    }

    // MARK: Pure — version comparison

    /// Numeric components of a version string: a leading "v"/"V" is dropped,
    /// each dot-separated piece keeps only its leading digits (so a tag like
    /// "v4.10-beta" reads as `[4, 10]`); a piece with no leading digits reads
    /// as 0. Comparisons pad the shorter side with zeros, so "4.1" == "4.1.0".
    static func versionComponents(_ raw: String) -> [Int] {
        var s = Substring(raw)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// True if `remote` names a strictly newer version than `current`.
    static func isNewer(_ remote: String, than current: String) -> Bool {
        let r = versionComponents(remote)
        let c = versionComponents(current)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    /// The release's DMG, if it published one (the release workflow in
    /// CLAUDE.md always attaches exactly one) — picked by extension rather
    /// than an assumed filename, since the name embeds the version.
    static func dmgAsset(in release: GitHubRelease) -> GitHubRelease.Asset? {
        release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    static func availability(for release: GitHubRelease, currentVersion: String) -> Availability {
        guard isNewer(release.tagName, than: currentVersion) else { return .upToDate }
        return .available(version: release.tagName, releaseURL: release.htmlURL, downloadURL: dmgAsset(in: release)?.downloadURL)
    }

    // MARK: Network

    static func fetchLatestRelease(session: URLSession = .shared) async throws -> GitHubRelease {
        var request = URLRequest(url: releasesAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CheckError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode
            throw CheckError.network(code.map { "HTTP \($0)" } ?? "no response")
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw CheckError.malformedResponse
        }
        return release
    }

    /// Downloads `url` into `~/Downloads` under `suggestedName` (de-duplicated
    /// against an existing file the way Safari does, "Name (1).dmg", …) and
    /// flags it quarantined, then returns its final location.
    static func downloadAsset(from url: URL, suggestedName: String, session: URLSession = .shared) async throws -> URL {
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(from: url)
        } catch {
            throw CheckError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode
            throw CheckError.network(code.map { "HTTP \($0)" } ?? "no response")
        }
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = (suggestedName as NSString).deletingPathExtension
        let ext = (suggestedName as NSString).pathExtension
        var destination = downloadsDir.appendingPathComponent(suggestedName)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloadsDir.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            throw CheckError.network(error.localizedDescription)
        }
        markAsQuarantinedDownload(destination)
        return destination
    }

    /// Flags the file as a quarantined internet download, the same as a
    /// browser would — so double-clicking the DMG goes through the normal
    /// Gatekeeper "downloaded from the internet, are you sure?" flow instead
    /// of silently skipping it just because our own app (not a browser)
    /// happened to be the one writing the file.
    private static func markAsQuarantinedDownload(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineType": "LSQuarantineTypeOtherDownload",
            "LSQuarantineAgentName": "Ngate2VPN",
        ]
        try? mutableURL.setResourceValues(values)
    }
}

/// `AppState`'s view of the last check — `AppUpdateChecker` itself is
/// stateless, this is what the Settings UI and the app-menu alert bind to.
enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(version: String, releaseURL: URL, downloadURL: URL?)
    case downloading(version: String)
    case failed(String)

    var availableVersion: String? {
        if case .available(let version, _, _) = self { return version }
        return nil
    }
}
