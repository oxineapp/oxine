import Foundation

/// One node of an app-declared view. Apps describe UI as trees of these; the
/// host renders them with PanelKit styling (`AppViewRenderer`). `id` makes a
/// node interactive — events carry it back as `ref`.
struct AppNode: Codable, Equatable, Sendable {
    var type: String
    var id: String?
    var props: [String: JSONValue]?
    var children: [AppNode]?

    // Prop accessors, defaulting-friendly.
    func string(_ key: String) -> String? { props?[key]?.stringValue }
    func number(_ key: String) -> Double? { props?[key]?.numberValue }
    func bool(_ key: String) -> Bool? { props?[key]?.boolValue }
    func strings(_ key: String) -> [String]? {
        props?[key]?.arrayValue?.compactMap { $0.stringValue }
    }
    func numbers(_ key: String) -> [Double]? {
        props?[key]?.arrayValue?.compactMap { $0.numberValue }
    }
}
