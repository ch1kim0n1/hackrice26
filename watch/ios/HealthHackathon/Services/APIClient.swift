import Foundation

enum APIError: LocalizedError {
    case invalidURL(String)
    case transport(Error)
    case badStatus(Int, String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "Backend URL is not valid: \(string)"
        case .transport(let error):
            return "Could not reach the backend: \(error.localizedDescription)"
        case .badStatus(let code, let body):
            if let body, !body.isEmpty {
                return "Backend returned HTTP \(code): \(body)"
            }
            return "Backend returned HTTP \(code)."
        case .decodingFailed:
            return "Backend response was not in the expected format."
        }
    }

    /// Network and 5xx problems are worth a retry; a 4xx means our payload is wrong.
    var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .badStatus(let code, _): return code >= 500
        case .invalidURL, .decodingFailed: return false
        }
    }
}

/// What the backend sends back from `POST /api/health`.
struct HealthUploadResponse: Decodable {
    let success: Bool
    let message: String?
    /// Free-form result from the backend's processing layer (ML/analysis output).
    let analysis: [String: String]?
}

/// Encodes a `HealthSnapshot` and POSTs it to the backend.
final class APIClient {

    static let shared = APIClient()

    private let session: URLSession

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// POST /vitals
    func send(_ snapshot: HealthSnapshot, baseURL: String = AppConfig.backendBaseURL) async throws -> HealthUploadResponse {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil else {
            throw APIError.invalidURL(baseURL)
        }
        components.path = (components.path as NSString)
            .appendingPathComponent("/vitals")
        guard let url = components.url else { throw APIError.invalidURL(baseURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = try encoder.encode(snapshot)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw APIError.badStatus(statusCode, String(data: data, encoding: .utf8))
        }

        do {
            return try decoder.decode(HealthUploadResponse.self, from: data)
        } catch {
            throw APIError.decodingFailed
        }
    }
}
