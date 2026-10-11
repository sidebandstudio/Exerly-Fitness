import SwiftUI
import UIKit

extension View {
    /// A swipe action for a row outside a List, where SwiftUI's
    /// `swipeActions` don't work: a swipe left uncovers the button, a long
    /// swipe acts at once, and a tap elsewhere on the row covers it again.
    /// Vertical drags still scroll. VoiceOver reaches the same action
    /// through the row's own actions.
    func exSwipeAction(_ title: String, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        modifier(ExSwipeAction(title: title, systemImage: systemImage, identifier: identifier, action: action))
    }
}

private struct ExSwipeAction: ViewModifier {
    let title: String
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @State private var offset: CGFloat = 0
    @State private var open = false
    @State private var rowWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 84

    func body(content: Content) -> some View {
        content
            // While open, a tap on the row covers the button again instead of opening the food.
            .overlay { if open { Color.clear.contentShape(Rectangle()).onTapGesture { settle(open: false) } } }
            .offset(x: offset)
            .background(alignment: .trailing) {
                // Only while uncovered, so VoiceOver and tests don't find one on every row.
                if offset < 0 {
                    Button { settle(open: false); action() } label: {
                        VStack(spacing: 4) {
                            Image(systemName: systemImage).font(.system(size: 17, weight: .semibold))
                            Text(title).font(.exSmall.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(width: max(width, -offset)).frame(maxHeight: .infinity)
                        .background(Color.exActionFill)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifier)
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .gesture(HorizontalPan { translation in
                offset = min(0, (open ? -width : 0) + translation)
            } ended: { translation, velocity in
                let reach = (open ? -width : 0) + translation
                if rowWidth > 0, reach < -rowWidth * 0.6 {
                    settle(open: false)
                    action()
                } else {
                    settle(open: reach < -width / 2 || velocity < -600)
                }
            })
    }

    private func settle(open: Bool) {
        withAnimation(.snappy) {
            self.open = open
            offset = open ? -width : 0
        }
    }
}

/// A pan that begins only when it moves more sideways than up or down, so it
/// never takes a scroll. Once it begins, the row's buttons don't also take
/// the touch as a tap, as they did when run 6 swiped across a food.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: changed(translation)
        case .ended, .cancelled: ended(translation, pan.velocity(in: pan.view).x)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
