import Foundation
import DSHPairing
import DSHTransport
import DSHTrust

/// Errors the pairing flow can surface to the user.
public enum PairingFlowError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missingToken
    case noURL
    case notACertificate
    case unexpectedStatus(Int)
    case instanceMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .missingToken:
            return "这条链接里没有配对 token，请在电脑面板重新生成"
        case .noURL:
            return "无法构造请求地址"
        case .notACertificate:
            return "/mobile-access/ca.cer 返回的不是证书"
        case .unexpectedStatus(let code):
            return "取 CA 失败：HTTP " + String(code) + "（404 表示该网关没有私有 CA）"
        case .instanceMismatch(let expected, let actual):
            return "CA 指纹与链接里的 instance 不一致（链接 "
                + String(expected.prefix(12)) + "… / CA " + String(actual.prefix(12)) + "…）"
        }
    }

    public var errorDescription: String? { description }
}

/// The one place allowed to talk TLS without a pinned CA, restricted to
/// /mobile-access/ca.cer (docs/04 section 2.3).
enum BootstrapCAFetcher {
    static func fetch(origin: GatewayOrigin) async throws -> CertificateAuthority {
        guard let url = origin.url(path: MobileAccessEndpoint.caCertificate.rawValue) else {
            throw PairingFlowError.noURL
        }

        let delegate = BootstrapOnlyTrustDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PairingFlowError.notACertificate }
        guard http.statusCode == 200 else { throw PairingFlowError.unexpectedStatus(http.statusCode) }
        guard let authority = CertificateAuthority.parse(data) else {
            throw PairingFlowError.notACertificate
        }
        return authority
    }
}
