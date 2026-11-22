import SwiftUI

struct TransactionsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Giao dịch", systemImage: "arrow.left.arrow.right")
            } description: {
                Text("Đang phát triển")
            }
            .navigationTitle("Giao dịch")
        }
    }
}

#Preview {
    TransactionsView()
}
