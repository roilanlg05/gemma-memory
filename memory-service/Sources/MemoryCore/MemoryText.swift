import Foundation

/// Single source of truth for memory label normalization. The small E4B often emits whole
/// sentences ("me gusta el sushi") or fragments ("me gusta") as labels; this turns them into
/// clean canonical entities for display and a stable key for dedup. Used by SaveMemoryTool
/// and MemoryStore's dedup so they all agree.
public enum MemoryText {
    private static let likePrefixes = [
        "me gustan ", "me gusta ", "le gusta ", "les gusta ",
        "i like ", "i love ", "likes ", "i prefer ", "my "
    ]
    private static let articlePrefixes = ["el ", "la ", "los ", "las ", "the ", "un ", "una ", "unos ", "unas "]

    /// Display label: trimmed, whitespace-collapsed, surrounding punctuation removed, and
    /// leading "I like"/article fillers stripped — but ORIGINAL CASE preserved ("Juan", "Messi").
    public static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:!¡¿?()[]"))
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for p in likePrefixes + articlePrefixes where lower.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return s
    }

    /// Case-insensitive dedup key derived from the clean label.
    public static func dedupKey(_ raw: String) -> String { cleanLabel(raw).lowercased() }

    /// Reduce an entity label to a canonical short form: strip common "the user's name is …"
    /// sentence prefixes (EN/ES) and cap to a short head so person/place/preference labels stay
    /// dedupable (the model sometimes returns whole sentences as a label).
    public static func canonicalEntityLabel(_ raw: String) -> String {
        var s = cleanLabel(raw)
        let prefixes = ["the user's name is ", "user's name is ", "the user is ", "user is ",
                        "el usuario se llama ", "usuario se llama ", "el usuario es ", "usuario es ",
                        "su nombre es ", "mi nombre es ",
                        "the user's ", "user's "]
        let lower = s.lowercased()
        for p in prefixes where lower.hasPrefix(p) {
            s = String(s.dropFirst(p.count)); break
        }
        let words = s.split(separator: " ")
        if words.count > 4 { s = words.prefix(4).joined(separator: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Canonical dedup key for an event: normalized title + start rounded to the minute.
    /// Collapses "10am"/"10:00"/"10:00:30" on the same title into one key.
    public static func eventCanonicalKey(title: String, startAt: Double) -> String {
        let minute = Int(startAt) / 60
        let normTitle = dedupKey(title)   // existing lowercase/whitespace/punct normalizer
        return "\(minute)|\(normTitle)"
    }

    /// Fillers / non-facts that should never be stored as a memory on their own.
    public static func isJunkLabel(_ raw: String) -> Bool {
        let k = dedupKey(raw)
        if k.isEmpty { return true }
        let junk: Set<String> = [
            "me gusta", "me gustan", "le gusta", "i like", "like", "likes", "gusta",
            "preferences", "preferencias", "preference", "stuff", "things", "cosas",
            "it", "that", "this", "eso", "esto", "user", "usuario"
        ]
        if junk.contains(k) { return true }
        // Reserved: NodeKind raw values and their hub labels are categories, never entities.
        let reserved = Set(NodeKind.allCases.map { $0.rawValue.lowercased() }
                         + NodeKind.allCases.map { $0.hubLabel.lowercased() })
        return reserved.contains(k)
    }
}
