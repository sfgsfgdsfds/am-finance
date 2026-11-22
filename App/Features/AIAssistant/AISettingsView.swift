import SwiftUI
import SwiftData

/// Màn hình cài đặt AI — danh sách cấu hình nhà cung cấp (một cấu hình đang
/// dùng), thêm / sửa / xoá, và ghi chú riêng tư rõ ràng. Pushed inside an
/// existing NavigationStack (from Settings); it must not wrap itself in one.
struct AISettingsView: View {
    private let store: AIProviderStore
    private let urlSession: URLSession

    @State private var profiles: [AIProviderProfile] = []
    @State private var activeID: UUID?
    @State private var showsAdd = false
    @State private var editing: AIProviderProfile?
    @State private var deleting: AIProviderProfile?

    init(
        store: AIProviderStore = AIProviderStore(),
        urlSession: URLSession = .shared
    ) {
        self.store = store
        self.urlSession = urlSession
    }

    var body: some View {
        List {
            Section {
                if profiles.isEmpty {
                    EmptyStateView(
                        symbol: "cpu.fill",
                        title: "Chưa có cấu hình AI",
                        message: "Thêm nhà cung cấp AI của bạn (OpenAI tương thích hoặc Anthropic) để dùng các tính năng phân tích và nhập liệu bằng ảnh.",
                        actionTitle: "Thêm cấu hình"
                    ) {
                        showsAdd = true
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(profiles) { profile in
                        row(profile)
                    }
                }
            } header: {
                Text("Nhà cung cấp")
            } footer: {
                if !profiles.isEmpty {
                    Text("Chạm ✓ để chọn cấu hình đang dùng. Vuốt để xoá — khoá API của cấu hình đó cũng bị xoá.")
                }
            }

            Section {
                Label(
                    "Dữ liệu tài chính chỉ rời khỏi iPhone khi bạn chủ động dùng một tính năng AI, và chỉ được gửi tới nhà cung cấp đã cấu hình tại đây. Khoá API lưu trong Keychain của máy, không đồng bộ.",
                    systemImage: "hand.raised.fill"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("Riêng tư")
            }
        }
        .navigationTitle("Trí tuệ nhân tạo (AI)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsAdd = true
                } label: {
                    Label("Thêm cấu hình", systemImage: "plus")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showsAdd, onDismiss: reload) {
            AIProfileEditView(store: store, urlSession: urlSession)
        }
        .sheet(item: $editing, onDismiss: reload) { profile in
            AIProfileEditView(profile: profile, store: store, urlSession: urlSession)
        }
        .alert(
            "Xoá cấu hình AI",
            isPresented: .init(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { profile in
            Button("Xoá", role: .destructive) {
                store.delete(profile.id)
                reload()
            }
            Button("Huỷ", role: .cancel) {}
        } message: { profile in
            Text("\"\(profile.name)\" và khoá API đã lưu sẽ bị xoá vĩnh viễn.")
        }
    }

    @ViewBuilder
    private func row(_ profile: AIProviderProfile) -> some View {
        HStack(spacing: 12) {
            Button {
                store.setActive(profile.id)
                reload()
            } label: {
                Image(
                    systemName: profile.id == activeID
                        ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        profile.id == activeID ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                profile.id == activeID ? "Đang dùng" : "Chọn cấu hình này")

            Button {
                editing = profile
            } label: {
                HStack(spacing: 12) {
                    IconBadge(
                        symbol: profile.style == .anthropic
                            ? "sparkles" : "brain",
                        colorHex: profile.style == .anthropic ? "AF52DE" : "0A84FF",
                        size: 32
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                        Text("\(profile.style.displayName) · \(profile.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = profile
            } label: {
                Label("Xoá", systemImage: "trash")
            }
        }
    }

    private func reload() {
        profiles = store.profiles()
        activeID = store.activeProfileID
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    let suiteName = "AISettingsPreview.\(UUID().uuidString)"
    let store = AIProviderStore(
        defaults: UserDefaults(suiteName: suiteName)!,
        keyStore: AIInMemoryAPIKeyStore())
    store.save(AIProviderProfile(
        name: "OpenAI của tôi", style: .openAICompatible,
        baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"))
    store.save(AIProviderProfile(
        name: "Claude tự host", style: .anthropic,
        baseURL: "https://ai.local", model: "claude-sonnet-4-5"))
    return NavigationStack {
        AISettingsView(store: store)
    }
    .modelContainer(container)
}
