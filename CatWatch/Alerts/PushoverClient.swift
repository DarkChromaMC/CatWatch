import Foundation

enum PushoverPriority: Int, CaseIterable, Identifiable {
    case quiet = -1
    case normal = 0
    case high = 1
    case emergency = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .quiet: return "Quiet"
        case .normal: return "Normal"
        case .high: return "High (bypasses quiet hours)"
        case .emergency: return "Emergency (repeats until acknowledged)"
        }
    }
}

struct PushoverError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal client for https://pushover.net/api
struct PushoverClient {
    let appToken: String
    let userKey: String

    static let endpoint = URL(string: "https://api.pushover.net/1/messages.json")!
    /// Pushover rejects attachments over 5 MB.
    static let maxAttachmentBytes = 5_000_000

    func send(
        title: String,
        message: String,
        priority: PushoverPriority = .normal,
        sound: String? = nil,
        jpeg: Data? = nil
    ) async throws {
        guard !appToken.isEmpty, !userKey.isEmpty else {
            throw PushoverError(message: "Pushover app token and user key are not set.")
        }
        var fields: [(String, String)] = [
            ("token", appToken),
            ("user", userKey),
            ("title", title),
            ("message", message),
            ("priority", String(priority.rawValue)),
        ]
        if priority == .emergency {
            fields.append(("retry", "60"))
            fields.append(("expire", "1800"))
        }
        if let sound, !sound.isEmpty { fields.append(("sound", sound)) }

        let attachment = jpeg.flatMap { $0.count <= Self.maxAttachmentBytes ? $0 : nil }
        let body = MultipartForm(fields: fields, file: attachment.map {
            .init(name: "attachment", filename: "catwatch.jpg", mimeType: "image/jpeg", data: $0)
        })

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body.data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 200, (json?["status"] as? Int) == 1 { return }
        let errors = (json?["errors"] as? [String])?.joined(separator: "; ")
        throw PushoverError(message: errors ?? "Pushover returned HTTP \(status).")
    }
}

struct MultipartForm {
    struct File {
        let name: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    let boundary: String
    let data: Data

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    init(fields: [(String, String)], file: File?) {
        let boundary = "CatWatch-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        if let file {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        self.boundary = boundary
        data = body
    }
}
