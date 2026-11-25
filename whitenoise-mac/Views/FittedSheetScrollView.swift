import SwiftUI

/// Keep a sheet's header and actions visible while long content scrolls between them.
struct FittedSheetScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        let preferredHeight = min(contentHeight ?? maximumHeight, maximumHeight)
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
        }
        .frame(minHeight: 0, idealHeight: preferredHeight, maxHeight: preferredHeight)
        .scrollBounceBehavior(.basedOnSize)
    }
}

#Preview {
    FittedSheetScrollView(maximumHeight: 300) {
        Text("Short content").padding()
    }
    .frame(width: 400)
}
