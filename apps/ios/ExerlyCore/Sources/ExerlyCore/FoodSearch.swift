import Foundation

/// Typed words matched to foods already on the device, as the food database
/// matches them: each word appears in the name or brand, in any order and
/// ignoring case and accents. When no food has every word, the foods with
/// the most of them, more than half, so "diced tomatoes canned" still finds
/// "Tomatoes, canned" but "ground beef" doesn't offer ground turkey above the
/// database's beef.
public enum FoodSearch {
    /// The query's words, folded for matching.
    public static func words(_ query: String) -> [String] {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The items whose text matches `query`: those with every word, the ones
    /// the query names first (see `names(_:query:)`) and otherwise in the
    /// order given, or else those with the most words, more than half, most
    /// first and otherwise in the order given.
    public static func matching<Item>(_ items: [Item], query: String, text: (Item) -> String) -> [Item] {
        let wanted = words(query)
        guard !wanted.isEmpty else { return [] }
        let found = items.map { item in
            let label = text(item)
            let folded = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return (item: item, label: label, count: wanted.filter { folded.contains($0) }.count)
        }
        let all = found.filter { $0.count == wanted.count }
        if !all.isEmpty || wanted.count == 1 {
            let ranked = all.map { ($0.item, names($0.label, query: query)) }
            return ranked.filter(\.1).map(\.0) + ranked.filter { !$0.1 }.map(\.0)
        }
        let enough = wanted.count / 2 + 1
        return found.enumerated().filter { $0.element.count >= enough }
            .sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }
            .map(\.element.item)
    }

    /// Whether `name` is the food `query` asks for rather than a dish named
    /// with it: its first comma-separated parts together, or one part alone,
    /// are the query's words in any order, plurals folded, and a part may be
    /// their "-ed" form. "Eggs, scrambled" names eggs and "Bread, toasted"
    /// toast; "French toast" doesn't name toast. The food database ranks its
    /// generic foods the same way.
    public static func names(_ name: String, query: String) -> Bool {
        let wanted = words(query).map(singular).sorted()
        guard !wanted.isEmpty else { return false }
        func asWanted(_ word: String) -> String {
            wanted.first { (want: String) -> Bool in word == want + "ed" || (want.hasSuffix("e") && word == want + "d") } ?? word
        }
        let parts: [[String]] = name.split(separator: ",").map { words(String($0)).map(singular).map(asWanted) }
        return parts.indices.contains { parts[...$0].joined().sorted() == wanted } || parts.contains { $0.sorted() == wanted }
    }

    /// A word in the singular, for matching: "eggs" is egg, "berries" berry.
    static func singular(_ word: String) -> String {
        if word.count > 3 && word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 3 && word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
