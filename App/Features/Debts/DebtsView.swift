import SwiftUI

struct DebtsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Nợ & Thẻ", systemImage: "creditcard.fill")
            } description: {
                Text("Đang phát triển")
            }
            .navigationTitle("Nợ & Thẻ")
        }
    }
}

#Preview {
    DebtsView()
}
