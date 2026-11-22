import SwiftUI
import SwiftData

struct RootTabView: View {
    @State private var quickAddShown = false

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
        .overlay(alignment: .bottom) {
            quickAddButton
        }
        .sheet(isPresented: $quickAddShown) {
            TransactionEditorView()
        }
    }

    /// Centered "+" floating over the tab bar's middle gap — the fastest way
    /// into a new transaction from anywhere in the app.
    private var quickAddButton: some View {
        Button {
            quickAddShown = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .accessibilityLabel("Thêm giao dịch")
        .accessibilityIdentifier("root.quickAdd")
        .padding(.bottom, 20)
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return RootTabView()
        .modelContainer(container)
}
