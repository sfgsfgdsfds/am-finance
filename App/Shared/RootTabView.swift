import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Tổng quan", systemImage: "house.fill")
                }
            TransactionsView()
                .tabItem {
                    Label("Giao dịch", systemImage: "arrow.left.arrow.right")
                }
            DebtsView()
                .tabItem {
                    Label("Nợ & Thẻ", systemImage: "creditcard.fill")
                }
            ReportsView()
                .tabItem {
                    Label("Báo cáo", systemImage: "chart.bar.fill")
                }
        }
    }
}

#Preview {
    RootTabView()
}
