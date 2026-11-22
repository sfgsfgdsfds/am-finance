import SwiftUI

/// Empty-list placeholder: symbol, title, an explanatory message and an
/// optional action button — the standard "nothing here yet" screen for every
/// feature. All strings are Vietnamese, supplied by the caller.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol.isEmpty ? AppTheme.fallbackSymbol : symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

#Preview {
    EmptyStateView(
        symbol: "arrow.left.arrow.right",
        title: "Chưa có giao dịch",
        message: "Giao dịch bạn ghi sẽ xuất hiện ở đây.",
        actionTitle: "Thêm giao dịch",
        action: {}
    )
}
