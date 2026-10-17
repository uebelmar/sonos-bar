import Foundation

public struct SOAPFault: Error, LocalizedError {
    /// UPnP error code (e.g. "714") or SOAP faultstring (SMAPI, e.g. "NOT_LINKED_RETRY").
    public let code: String
    public let detail: XElement?

    public var errorDescription: String? {
        switch code {
        case "701": "Übergang nicht möglich (701)"
        case "714": "Ungültiger Inhalt (714)"
        case "800": "Lautsprecher lehnt Befehl ab (800)"
        case "804": "Nicht unterstützt (804)"
        default: "Sonos-Fehler \(code)"
        }
    }
}

enum SOAP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    static func envelope(action: String, namespace: String, args: [(String, String)], header: String? = nil) -> String {
        let params = args.map { "<\($0.0)>\($0.1.xmlEscaped)</\($0.0)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        \(header.map { "<s:Header>\($0)</s:Header>" } ?? "")\
        <s:Body><u:\(action) xmlns:u="\(namespace)">\(params)</u:\(action)></s:Body></s:Envelope>
        """
    }

    /// POSTs the envelope and returns the first element inside `<s:Body>`
    /// (the `<…Response>` element). Throws `SOAPFault` on a SOAP fault.
    static func call(url: URL, soapAction: String, body: String) async throws -> XElement {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(soapAction)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, _) = try await session.data(for: request)
        guard let root = XElement.parse(data), let bodyNode = root.child("Body"),
              let response = bodyNode.children.first
        else { throw SOAPFault(code: "invalid-response", detail: nil) }

        if response.name == "Fault" {
            let code = response.first("errorCode")?.text
                ?? response.value("faultstring")
                ?? "unknown"
            throw SOAPFault(code: code.trimmingCharacters(in: .whitespacesAndNewlines), detail: response.child("detail"))
        }
        return response
    }
}
