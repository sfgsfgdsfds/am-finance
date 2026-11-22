import SwiftUI

struct DashboardView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Tổng quan", systemImage: "house.fill")
            } description: {
                Text("Đang phát triển")
            }
            .navigationTitle("Tổng quan")
        }
    }
}

#Preview {
    DashboardView()
}
