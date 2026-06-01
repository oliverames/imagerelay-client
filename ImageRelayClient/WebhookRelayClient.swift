import Foundation
import ImageRelayKit

struct WebhookRelayClient: Sendable {
    struct PollResult: Sendable {
        let events: [Event]
        let cursor: String?

        var hasChanges: Bool { !events.isEmpty }
    }

    struct Event: Decodable, Sendable, Identifiable {
        let id: String
        let resource: String?
        let action: String?
        let folderID: Int?
        let fileID: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case resource
            case action
            case folderID = "folder_id"
            case fileID = "file_id"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            resource = try c.decodeIfPresent(String.self, forKey: .resource)
            action = try c.decodeIfPresent(String.self, forKey: .action)
            folderID = try c.decodeIfPresent(Int.self, forKey: .folderID)
            fileID = try c.decodeIfPresent(Int.self, forKey: .fileID)
        }
    }

    private struct Response: Decodable, Sendable {
        let events: [Event]
        let cursor: String?
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case events
            case cursor
            case nextCursor = "next_cursor"
        }
    }

    func poll(url: URL, cursor: String?, timeoutSeconds: Int) async throws -> PollResult {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        queryItems.append(URLQueryItem(name: "timeout", value: "\(max(1, timeoutSeconds))"))
        components?.queryItems = queryItems

        guard let requestURL = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: requestURL)
        request.setValue(AppConfiguration.currentServiceUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = TimeInterval(max(10, timeoutSeconds + 5))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder.imageRelay.decode(Response.self, from: data)
        let nextCursor = decoded.nextCursor ?? decoded.cursor ?? decoded.events.last?.id ?? cursor
        return PollResult(events: decoded.events, cursor: nextCursor)
    }
}
