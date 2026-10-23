import Foundation

extension TodayLayout {
    /// The cards Today's first frame draws; the rest follow a frame later
    /// (PARITY B03). The first three, whatever they are, and everything down
    /// to the last of the logging tools: the shortcuts, the ring Log again
    /// follows, and today's workout with Start. A customized order never
    /// defers them, nor a card above them, which would move them down a
    /// frame after launch placed them.
    static func drawnFirst(_ visible: [Card]) -> Set<Card> {
        let through = visible.lastIndex { [.quickActions, .nutrition, .training].contains($0) }.map { $0 + 1 } ?? 0
        return Set(visible.prefix(max(3, through)))
    }
}
