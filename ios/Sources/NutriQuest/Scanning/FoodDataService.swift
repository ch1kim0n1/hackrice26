import Foundation

public enum FoodDataError: LocalizedError {
    case network(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .network(let e): return "Network error: \(e.localizedDescription)"
        case .invalidResponse: return "Unexpected response from product database."
        }
    }
}

/// Looks up product data for a barcode using the free Open Food Facts /
/// Open Products Facts APIs (no API key, no quota).
public struct FoodDataService {
    public static let shared = FoodDataService()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    private var endpoints: [String] {
        [
            "https://world.openfoodfacts.org/api/v2/product",
            "https://world.openproductsfacts.org/api/v2/product"
        ]
    }

    /// Returns nil when the barcode is unknown to all databases.
    public func lookup(barcode: String) async throws -> FoodProduct? {
        for base in endpoints {
            guard let url = URL(string: "\(base)/\(barcode).json") else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BarcodeScanner - iOS - Version 1.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw FoodDataError.invalidResponse }
                if http.statusCode == 404 { continue }

                let decoded = try JSONDecoder().decode(OFFResponse.self, from: data)
                if decoded.status == 1, let product = decoded.product {
                    return product
                }
            } catch is DecodingError {
                continue
            } catch {
                throw FoodDataError.network(error)
            }
        }
        return nil
    }
}
