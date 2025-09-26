import Foundation

struct HTTPClient {
    let baseURL: URL?
    let headers: [String: String]

    init(settings: AppSettings, overrideHeaderText: String = "") {
        baseURL = settings.httpBaseURL.flatMap { URL(string: $0) }
        func parseHeaders(_ text: String) -> [String: String] {
            var dict: [String: String] = [:]
            text.split(separator: "\n")
                .map { $0.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) } }
                .forEach { pair in
                    if pair.count == 2 {
                        dict[pair[0]] = pair[1]
                    }
                }
            return dict
        }
        var headerDict = parseHeaders(settings.httpHeadersText)
        headerDict.merge(parseHeaders(overrideHeaderText)) { $1 }
        if let token = KeychainHelper.read("http_token"), !token.isEmpty {
            headerDict["Authorization"] = "Bearer \(token)"
        }
        headers = headerDict
    }

    func send(path: String, method: HTTPMethod, body: String?) async throws -> (Data, URLResponse) {
        guard let baseURL else { throw URLError(.badURL) }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method.rawValue
        request.allHTTPHeaderFields = headers
        if let body {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = body.data(using: .utf8)
        }
        return try await URLSession.shared.data(for: request)
    }

    func getStatus(path: String, method: HTTPMethod) async throws -> (Data, URLResponse) {
        try await send(path: path, method: method, body: nil)
    }
}
