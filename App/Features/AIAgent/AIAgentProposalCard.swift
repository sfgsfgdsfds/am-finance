import SwiftUI

/// The pending write batch parked on `AIAgentChatSession.pendingProposal`,
/// rendered at the end of the conversation: the model's short explanation,
/// one row per proposed action (a kind badge plus its field lines) and the
/// two decisions. "Áp dụng" IS the confirmation — one tap applies the whole
/// batch atomically through `confirmProposal()`, there is no second dialog.
/// A batch carrying deletes styles the button destructive and says so in
/// the label. While the card sits here the input stays usable — a new
/// message discards the proposal, which the hint line says out loud.
struct AIAgentProposalCard: View {
    let proposal: AIAgentActionProposal
    var onApply: () -> Void
    var onDiscard: () -> Void

    /// "Áp dụng 1 thay đổi" / "Áp dụng 3 thay đổi (xoá 1)" — the delete
    /// count rides in the label so a destructive batch announces itself.
    static func applyTitle(itemCount: Int, deleteCount: Int) -> String {
        let base = "Áp dụng \(itemCount) thay đổi"
        guard deleteCount > 0 else { return base }
        return "\(base) (xoá \(deleteCount))"
    }

    /// One display line per field change: `field: old → new` for edits and
    /// re-categorizations, `field: new` for adds, `field: old` for deletes.
    static func fieldLine(
        _ change: AIAgentProposalItem.FieldChange
    ) -> String {
        switch (change.old, change.new) {
        case let (old?, new?):
            return "\(change.field): \(old) → \(new)"
        case let (nil, new?):
            return "\(change.field): \(new)"
        case let (old?, nil):
            return "\(change.field): \(old)"
        case (nil, nil):
            return change.field
        }
    }

    private var deleteCount: Int {
        proposal.items.filter { $0.kind == .delete }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.text)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(proposal.items) { item in
                itemRow(item)
            }

            Text("Gửi tin nhắn mới sẽ bỏ qua đề xuất này.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    onApply()
                } label: {
                    Text(Self.applyTitle(
                        itemCount: proposal.items.count,
                        deleteCount: deleteCount))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(deleteCount > 0 ? AppTheme.expense : Color.accentColor)
                .accessibilityIdentifier("agent.proposal.apply")

                Button("Bỏ qua") {
                    onDiscard()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("agent.proposal.discard")
            }
        }
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14))
    }

    /// One proposed action: the kind badge ("Thêm"/"Sửa"/"Xoá"/"Phân loại")
    /// — delete in the expense red — then its field lines.
    private func itemRow(_ item: AIAgentProposalItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.kind.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badgeColor(item.kind), in: Capsule())
            ForEach(item.changes) { change in
                Text(Self.fieldLine(change))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Badge tint per kind — only delete goes red; the rest stay neutral.
    private func badgeColor(_ kind: AIAgentProposalItemKind) -> Color {
        switch kind {
        case .delete: return AppTheme.expense
        case .add: return AppTheme.income
        case .edit, .setCategory: return Color.accentColor
        }
    }
}

#Preview {
    ScrollView {
        AIAgentProposalCard(
            proposal: AIAgentActionProposal(
                text: "Đề xuất một đợt dọn sổ nhỏ.",
                items: [
                    AIAgentProposalItem(
                        kind: .add,
                        changes: [
                            .init(field: "Loại", new: "Chi tiêu"),
                            .init(field: "Số tiền", new: "50.000 ₫"),
                            .init(field: "Ghi chú", new: "Phở UI test"),
                        ]),
                    AIAgentProposalItem(
                        kind: .setCategory, row: "R3",
                        changes: [
                            .init(field: "Danh mục", old: "Chưa phân loại",
                                  new: "Ăn uống"),
                        ]),
                    AIAgentProposalItem(
                        kind: .edit, row: "R2",
                        changes: [
                            .init(field: "Số tiền", old: "60.000 ₫",
                                  new: "75.000 ₫"),
                        ]),
                    AIAgentProposalItem(
                        kind: .delete, row: "R1",
                        changes: [
                            .init(field: "Số tiền", old: "10.000 ₫"),
                            .init(field: "Ghi chú", old: "xài"),
                        ]),
                ]),
            onApply: {},
            onDiscard: {})
        .padding(12)
    }
    .background(Color(.systemGroupedBackground))
}
