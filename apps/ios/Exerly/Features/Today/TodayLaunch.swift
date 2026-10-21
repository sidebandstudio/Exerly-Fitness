import Foundation

extension TodayLayout {
    /// The cards Today's first frame draws; the rest follow a frame later
    /// (PARITY B03). The first three, whatever they are, and wherever they
    /// are the logging tools: the shortcuts, the ring Log again follows, and
    /// today's workout with Start. A customized order never defers them.
    static func drawnFirst(_ visible: [Card]) -> Set<Card> {
        Set(visible.prefix(3)).union(visible.filter { [.quickActions, .nutrition, .training].contains($0) })
    }
}
