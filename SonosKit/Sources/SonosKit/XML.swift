import Foundation

/// Minimal DOM over `XMLParser`. Element names are stored without namespace
/// prefix (`dc:title` → `title`) — Sonos XML never relies on the prefix.
public final class XElement {
    public let name: String
    public let attributes: [String: String]
    public fileprivate(set) var children: [XElement] = []
    public fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public subscript(attribute: String) -> String? { attributes[attribute] }

    public func child(_ name: String) -> XElement? {
        children.first { $0.name == name }
    }

    public func children(_ name: String) -> [XElement] {
        children.filter { $0.name == name }
    }

    /// Text of the direct child `name`, or nil.
    public func value(_ name: String) -> String? { child(name)?.text }

    /// Depth-first search for the first element called `name`.
    public func first(_ name: String) -> XElement? {
        for c in children {
            if c.name == name { return c }
            if let hit = c.first(name) { return hit }
        }
        return nil
    }

    public static func parse(_ data: Data) -> XElement? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    public static func parse(_ string: String) -> XElement? {
        parse(Data(string.utf8))
    }
}

private func localName(_ qualified: String) -> String {
    qualified.split(separator: ":").last.map(String.init) ?? qualified
}

private final class Builder: NSObject, XMLParserDelegate {
    var root: XElement?
    private var stack: [XElement] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XElement(name: localName(elementName), attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

extension String {
    /// Escapes for use as XML text or attribute value.
    public var xmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for ch in self {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
