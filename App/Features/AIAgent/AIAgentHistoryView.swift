import SwiftUI
import SwiftData

/// "Lịch sử" — every saved Agent conversation, newest first. A row
/// shows the title (the first user message), when it was last updated
/// and its message count; the conversation currently open is marked.
/// Tapping a row restores it into the shared session and pops back to
/// the chat; swiping deletes a single entry; "Xoá tất cả" wipes the
/// whole list behind a confirmation.
///
/// Pushed from the Agent screen's toolbar inside the same
/// NavigationStack — no stack of its own.
@MainActor
struct AIAgentHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Tests and previews may inject a controller; nil resolves to the
    /// shared per-container one — same pattern as `AIAgentView`.
    private let injectedController: AIAgentController?

    @State private var confirmClearAll = false

    init(controller: AIAgentController? = nil) {
        self.injectedController = controller
    }

    private var controller: AIAgentController {
        injectedController
            ?? AIAgentControllers.shared(for: context.container)
    }

    var body: some View {
        Group {
            if controller.conversations.isEmpty {
                EmptyStateView(
                    symbol: "clock",
                    title: "Chưa có cuộc trò chuyện nào",
                    message: "Cuộc trò chuyện với Agent được lưu tự động và sẽ hiện ở đây.")
            } else {
                conversationList
            }
        }
        .navigationTitle("Lịch sử")
        .toolbar {
            if !controller.conversations.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xoá tất cả", role: .destructive) {
                        confirmClearAll = true
                    }
                    .accessibilityIdentifier("agent.history.clearAll")
                }
            }
        }
        .confirmationDialog(
            "Xoá toàn bộ lịch sử?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Xoá tất cả", role: .destructive) {
                controller.deleteAllConversations()
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Mọi cuộc trò chuyện đã lưu sẽ bị xoá vĩnh viễn.")
        }
        .onAppear { controller.reloadConversations() }
    }

    private var conversationList: some View {
        List {
            ForEach(controller.conversations) { item in
                row(item)
                    .contentShape(Rectangle())
                    // Plain row + onTapGesture: List-row Button actions
                    // do not fire on iOS 26.
                    .onTapGesture {
                        controller.openConversation(item.id)
                        dismiss()
                    }
            }
            .onDelete { offsets in
                for index in offsets {
                    controller.deleteConversation(
                        controller.conversations[index].id)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ item: AIAgentConversationSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.id == controller.currentConversationID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Đang mở")
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("agent.history.row.\(item.id.uuidString)")
    }

    /// "Hôm nay 14:05 · 12 tin nhắn".
    private func subtitle(_ item: AIAgentConversationSummary) -> String {
        AppDateFormat.dayHeader(item.updatedAt, now: .now)
            + " " + AppDateFormat.time(item.updatedAt)
            + " · \(item.messageCount) tin nhắn"
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    return NavigationStack {
        AIAgentHistoryView()
    }
    .modelContainer(container)
}
