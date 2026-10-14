import Foundation
import Security

@objc public protocol PowerFanServiceProtocol {
    func execute(_ command: String, withReply reply: @escaping (String) -> Void)
}

public enum PowerFanService {
    public static let appIdentifier = "local.yun.PowerView"
    public static let identifier = "local.yun.PowerView.FanService"
    public static let plistName = identifier + ".plist"

    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\" "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }

    /// Derive trust from our running code, never a caller-supplied path or Team ID.
    /// Ad-hoc builds cannot expose a persistent privileged service.
    public static func signingTeam(identifier: String) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        var expected: SecRequirement?
        guard SecRequirementCreateWithString(requirement(identifier: identifier, team: team) as CFString, [], &expected) == errSecSuccess,
              let expected,
              SecCodeCheckValidity(code, [], expected) == errSecSuccess else { return nil }
        return team
    }
}

public enum FanServiceError: LocalizedError {
    case disconnected, timedOut
    public var errorDescription: String? {
        switch self {
        case .disconnected: return "风扇服务连接失败，请检查系统设置中的后台服务批准状态。"
        case .timedOut: return "风扇服务响应超时，服务会尝试恢复系统自动。"
        }
    }
}

private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func finish(_ result: Result<String, Error>) {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        saved?.resume(with: result)
    }
}

public final class FanServiceConnection {
    private let connection: NSXPCConnection

    public init(team: String) {
        connection = NSXPCConnection(machServiceName: PowerFanService.identifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerFanServiceProtocol.self)
        connection.setCodeSigningRequirement(PowerFanService.requirement(identifier: PowerFanService.identifier, team: team))
        connection.resume()
    }

    deinit { connection.invalidate() }
    public func close() { connection.invalidate() }

    public func execute(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                pending.finish(.failure(FanServiceError.timedOut))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                pending.finish(.failure(FanServiceError.disconnected))
            }) as? PowerFanServiceProtocol else {
                pending.finish(.failure(FanServiceError.disconnected))
                return
            }
            proxy.execute(command) { pending.finish(.success($0)) }
        }
    }
}
