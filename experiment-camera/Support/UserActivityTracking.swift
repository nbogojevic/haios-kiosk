import SwiftUI

private struct UserActivityTrackingModifier: ViewModifier {
    let onUserActivity: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(TapGesture().onEnded {
                onUserActivity()
            })
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
                onUserActivity()
            })
    }
}

extension View {
    func trackUserActivity(_ onUserActivity: @escaping () -> Void) -> some View {
        modifier(UserActivityTrackingModifier(onUserActivity: onUserActivity))
    }
}
