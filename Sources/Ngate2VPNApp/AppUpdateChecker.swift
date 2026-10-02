import Foundation

/// Checks GitHub Releases for a newer version. The app has no Developer ID or
/// notarization, so this never downloads or installs anything itself — even a
/// freshly-downloaded build still needs the user to clear Gatekeeper once (see
/// README → Установка). "Update" here means "find out a newer version exists
/// and hand the user a link," nothing more.
enum AppUpdateChecker {
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/MoonMig/Ngate2VPN/releases/latest")!

    /// The fields we need from GitHub's Releases API response.
    struct GitHubRelease: Decodable, Equatable {
        let tagName: String
        let htmlURL: URL

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    enum Availability: Equatable {
        case upToDate
        case available(version: String, url: URL)
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

    static func availability(for release: GitHubRelease, currentVersion: String) -> Availability {
        guard isNewer(release.tagName, than: currentVersion) else { return .upToDate }
        return .available(version: release.tagName, url: release.htmlURL)
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
}

/// `AppState`'s view of the last check — `AppUpdateChecker` itself is
/// stateless, this is what the Settings UI binds to.
enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(version: String, url: URL)
    case failed(String)
}
