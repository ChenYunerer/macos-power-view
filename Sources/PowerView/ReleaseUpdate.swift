import Foundation
import CryptoKit
import UpdateSupport

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int64
        let browser_download_url: URL
        let digest: String?
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [Asset]
    var version: String { String(tag_name.dropFirst()) }
    var zipName: String { "Power-View-\(version)-macOS-arm64.zip" }

    func asset(named name: String) throws -> Asset {
        let matches = assets.filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first, asset.size > 0, asset.size <= 100_000_000,
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/ChenYunerer/macos-power-view/releases/download/\(tag_name)/\(name)" else {
            throw UpdateFailure("Release 缺少有效的 \(name) 附件。")
        }
        return asset
    }
}

actor ReleaseUpdate {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    func latest() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ChenYunerer/macos-power-view/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PowerView-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, [403, 429].contains(http.statusCode) {
            return try await latestFromAssets()
        }
        try check(response)
        guard data.count <= 2_000_000 else { throw UpdateFailure("Release 信息过大。") }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v"), ReleaseVersion(release.version) != nil else {
            throw UpdateFailure("GitHub 尚未提供可用的正式版本。")
        }
        _ = try release.asset(named: release.zipName)
        return release
    }

    private func latestFromAssets() async throws -> GitHubRelease {
        // Published attachments are also public when GitHub's anonymous API
        // quota is exhausted. Pin subsequent requests to this exact version.
        let base = "https://github.com/ChenYunerer/macos-power-view/releases"
        let (data, response) = try await session.data(from: URL(string: base + "/latest/download/build-info.json")!)
        try check(response)
        struct Metadata: Decodable {
            let version: String
            let signing: String
            let notarized: Bool
            let architecture: String
        }
        guard data.count < 32_000 else { throw UpdateFailure("Release 元数据大小异常。") }
        let info = try JSONDecoder().decode(Metadata.self, from: data)
        guard ReleaseVersion(info.version) != nil, info.signing == "developer-id",
              info.notarized, info.architecture == "arm64" else {
            throw UpdateFailure("GitHub 尚未提供符合要求的正式更新包。")
        }
        let tag = "v" + info.version
        var assets: [GitHubRelease.Asset] = []
        for name in ["Power-View-\(info.version)-macOS-arm64.zip", "SHA256SUMS.txt"] {
            let url = URL(string: base + "/download/\(tag)/\(name)")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: request)
            try check(response)
            guard response.expectedContentLength > 0 else { throw UpdateFailure("无法确认更新附件大小，请稍后重试。") }
            assets.append(.init(name: name, size: response.expectedContentLength, browser_download_url: url, digest: nil))
        }
        let release = GitHubRelease(tag_name: tag, draft: false, prerelease: false, body: nil, assets: assets)
        _ = try release.asset(named: release.zipName)
        return release
    }

    func prepare(_ release: GitHubRelease, team: String,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: UpdateFiles.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let work = UpdateFiles.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            return try await doPrepare(release, work: work, team: team, progress: progress)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private func doPrepare(_ release: GitHubRelease, work: URL, team: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let archive = try release.asset(named: release.zipName)
        let checksumAsset = try release.asset(named: "SHA256SUMS.txt")
        guard checksumAsset.size < 32_000 else { throw UpdateFailure("校验和文件大小异常。") }
        let (checksums, response) = try await session.data(from: checksumAsset.browser_download_url)
        try check(response)
        guard checksums.count == checksumAsset.size else { throw UpdateFailure("校验和文件下载不完整。") }
        let matches = String(decoding: checksums, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, String(parts[1]) == release.zipName else { return nil }
            return String(parts[0]).lowercased()
        }
        guard matches.count == 1, let expected = matches.first,
              expected.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              archive.digest == nil || archive.digest == "sha256:" + expected else {
            throw UpdateFailure("Release 校验和不一致。")
        }
        let zip = work.appendingPathComponent("update.zip")
        fm.createFile(atPath: zip.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let file = try FileHandle(forWritingTo: zip)
        defer { try? file.close() }
        let (bytes, downloadResponse) = try await session.bytes(from: archive.browser_download_url)
        try check(downloadResponse)
        var buffer = Data()
        var hash = SHA256()
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 65_536 {
                try Task.checkCancellation()
                received += Int64(buffer.count)
                guard received <= archive.size else { throw UpdateFailure("下载大小超出 Release 声明。") }
                hash.update(data: buffer)
                try file.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(Double(received) / Double(archive.size))
            }
        }
        received += Int64(buffer.count)
        hash.update(data: buffer)
        try file.write(contentsOf: buffer)
        try file.close()
        guard received == archive.size,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw UpdateFailure("下载不完整或 SHA-256 校验失败，请重新下载。")
        }
        try Task.checkCancellation()
        progress(1)
        let app = try UpdateFiles.extract(zip: zip, into: work.appendingPathComponent("unpacked"))
        try UpdateFiles.validate(app: app, version: release.version, team: team)
        try Task.checkCancellation()
        return app
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
            throw UpdateFailure("GitHub 返回了无效响应。")
        }
        switch http.statusCode {
        case 200: return
        case 403, 429: throw UpdateFailure("GitHub 请求暂时受限，请稍后重试。")
        case 404: throw UpdateFailure("GitHub 尚无可下载的正式 Release。")
        default: throw UpdateFailure("GitHub 请求失败（HTTP \(http.statusCode)），请稍后重试。")
        }
    }
}
