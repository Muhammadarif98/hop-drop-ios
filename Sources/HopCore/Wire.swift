import Foundation

public enum HopError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public enum HopValidation {
    public static func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }
    public static func localAddress(_ input: String) -> Bool {
        let host = input.lowercased().replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").split(separator: "%").first.map(String.init) ?? ""
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") && host.contains(":") || host.hasPrefix("fd") && host.contains(":") { return true }
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 4, segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let parts = segments.compactMap { Int($0) }; guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || parts[0] == 192 && parts[1] == 168 || parts[0] == 172 && (16...31).contains(parts[1]) || parts[0] == 169 && parts[1] == 254
    }
}
public enum SafePath {
    public static func components(_ value: String) throws -> [String] {
        guard !value.isEmpty, value.utf8.count <= 2048, !value.hasPrefix("/"), !value.contains("\\"), !value.contains(":"), !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw HopError.invalid("Недопустимый путь файла") }
        let parts = value.components(separatedBy: "/")
        guard parts.count <= 25, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw HopError.invalid("Недопустимый путь файла") }
        return parts
    }
    public static func destination(_ components: [String], in root: URL) throws -> URL {
        let url = components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw HopError.invalid("Путь вне папки Hop") }; return url
    }
}
public struct HTTPHead {
    public let method: String, target: String, headers: [String: String], length: Int64
    public var url: URL { URL(string: "http://hop" + target)! }
    public var path: String { url.path }
    public func query(_ name: String) -> String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value }
    public static func parse(_ data: Data) throws -> HTTPHead {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { throw HopError.invalid("Bad HTTP header") }
        let lines = text.components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0", first[1].hasPrefix("/"), !first[1].hasPrefix("//"), let url = URL(string: "http://hop" + first[1]), url.host == "hop" else { throw HopError.invalid("Bad HTTP request") }
        var headers = [String: String]()
        for line in lines.dropFirst() where !line.isEmpty {
            guard headers.count < 80, let colon = line.firstIndex(of: ":") else { throw HopError.invalid("Bad HTTP header") }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { throw HopError.invalid("Duplicate HTTP header") }; headers[key] = value
        }
        guard headers["transfer-encoding"] == nil, let length = Int64(headers["content-length"] ?? "0"), length >= 0 else { throw HopError.invalid("Bad content length") }
        return HTTPHead(method: String(first[0]), target: String(first[1]), headers: headers, length: length)
    }
}
