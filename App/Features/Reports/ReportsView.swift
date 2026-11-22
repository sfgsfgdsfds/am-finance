import SwiftUI

struct ReportsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Báo cáo", systemImage: "chart.bar.fill")
            } description: {
                Text("Đang phát triển")
            }
            .navigationTitle("Báo cáo")
        }
    }
}

#Preview {
    ReportsView()
}
