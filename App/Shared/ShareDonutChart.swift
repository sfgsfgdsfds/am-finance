import SwiftUI
import Charts
import FinanceCore

/// One slice of a `ShareDonutChart`: a stable id for selection callbacks,
/// the display name, a non-negative đồng magnitude and the model color hex
/// ("RRGGBB" — empty or invalid falls back to the shared palette).
struct ShareDonutSlice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var amount: Int64
    var colorHex: String

    init(id: String, name: String, amount: Int64, colorHex: String = "") {
        self.id = id
        self.name = name
        self.amount = max(0, amount)
        self.colorHex = colorHex
    }
}

/// The pure math behind `ShareDonutChart` — sorting, "Khác" folding,
/// integer percents and color fallbacks — kept view-free so share builders
/// and tests can use it without SwiftUI.
enum ShareDonutMath {
    /// Maximum slices drawn before the tail folds into "Khác".
    static let sliceLimit = 6
    /// Identity/label/color of the folded slice — stable so selection and
    /// legends agree with builders that fold the same way.
    static let otherID = "__other"
    static let otherName = "Khác"
    static let otherColorHex = "8E8E93"

    /// Descending by amount; deterministic ties by name then id so chart
    /// order never depends on dictionary iteration.
    static func sorted(_ slices: [ShareDonutSlice]) -> [ShareDonutSlice] {
        slices.sorted { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
    }

    /// At most `limit` slices plus a trailing "Khác" slice holding the
    /// folded sum — never emitted when everything fits. Idempotent: an
    /// incoming "Khác" slice merges into the folded total instead of
    /// sorting alongside the kept slices.
    static func folded(
        _ slices: [ShareDonutSlice],
        limit: Int = sliceLimit
    ) -> [ShareDonutSlice] {
        var regulars: [ShareDonutSlice] = []
        var rest: Int64 = 0
        var hasOther = false
        for slice in slices {
            if slice.id == otherID {
                hasOther = true
                rest = saturatingAdd(rest, slice.amount)
            } else {
                regulars.append(slice)
            }
        }
        let ordered = sorted(regulars)
        let kept = max(0, limit)
        guard ordered.count > kept || hasOther else { return ordered }
        for slice in ordered.dropFirst(kept) {
            rest = saturatingAdd(rest, slice.amount)
        }
        return Array(ordered.prefix(kept)) + [
            ShareDonutSlice(
                id: otherID, name: otherName,
                amount: rest, colorHex: otherColorHex)
        ]
    }

    /// Whole percents of the total, largest-remainder rounded so they sum
    /// to exactly 100 (all zeros when the total is 0). Ties favour the
    /// larger amount, then the earlier position — deterministic.
    static func percents(amounts: [Int64]) -> [Int] {
        let total = amounts.reduce(Int64(0), saturatingAdd)
        guard total > 0 else { return amounts.map { _ in 0 } }
        let exact = amounts.map { Double($0) / Double(total) * 100 }
        var rounded = exact.map { Int($0.rounded(.down)) }
        var remainder = 100 - rounded.reduce(0, +)
        let order = amounts.indices.sorted { i, j in
            let fi = exact[i] - Double(rounded[i])
            let fj = exact[j] - Double(rounded[j])
            if fi != fj { return fi > fj }
            if amounts[i] != amounts[j] { return amounts[i] > amounts[j] }
            return i < j
        }
        for index in order where remainder > 0 {
            rounded[index] += 1
            remainder -= 1
        }
        return rounded
    }

    /// Display hex per slice, in order. A slice keeps its own color when it
    /// parses and is unique in the chart; missing, invalid or duplicated
    /// colors fall back to palette entries not yet used (cycling when the
    /// palette runs out).
    static func resolvedColorHexes(
        _ slices: [ShareDonutSlice],
        palette: [String]
    ) -> [String] {
        var used = Set<String>()
        var resolved: [String] = []
        resolved.reserveCapacity(slices.count)
        var paletteIndex = 0
        let fallback = palette.compactMap(normalizedHex)
        for slice in slices {
            if let hex = normalizedHex(slice.colorHex), !used.contains(hex) {
                used.insert(hex)
                resolved.append(hex)
                continue
            }
            var chosen = ""
            for _ in 0..<max(1, fallback.count) where !fallback.isEmpty {
                let candidate = fallback[paletteIndex % fallback.count]
                paletteIndex += 1
                if !used.contains(candidate) {
                    chosen = candidate
                    break
                }
            }
            if chosen.isEmpty {
                chosen = fallback.isEmpty
                    ? otherColorHex
                    : fallback[paletteIndex % fallback.count]
            }
            used.insert(chosen)
            resolved.append(chosen)
        }
        return resolved
    }

    /// "RRGGBB" uppercase, or nil when `raw` is not a six-digit hex color.
    static func normalizedHex(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        text = text.uppercased()
        return HexColor.parse(text) == nil ? nil : text
    }

    static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? (a < 0 ? .min : .max) : result
    }
}

/// Reusable spending-share donut: a `SectorMark` ring that folds everything
/// past six slices into "Khác", labels slices of at least 5%, shows the
/// total (or the tapped slice's name, amount and percent) in the centre,
/// and lists a legend with color dot, name, amount and percent below —
/// descending, like the chart order. Tap or drag on the ring (or tap a
/// legend row) to select; selection is reported through `onSelect`.
struct ShareDonutChart: View {
    let slices: [ShareDonutSlice]
    /// Centre caption under no selection — e.g. "Tổng chi".
    let totalTitle: String
    /// Semantic coloring for the total and legend amounts.
    let kind: TransactionKind
    let onSelect: ((ShareDonutSlice?) -> Void)?

    /// Cumulative angle under the finger while touching the ring.
    @State private var rawAngle: Double?
    @State private var selectedID: String?
    @State private var touchActive = false

    init(
        slices: [ShareDonutSlice],
        totalTitle: String = "Tổng",
        kind: TransactionKind = .expense,
        onSelect: ((ShareDonutSlice?) -> Void)? = nil
    ) {
        self.slices = slices
        self.totalTitle = totalTitle
        self.kind = kind
        self.onSelect = onSelect
    }

    /// Sorted, folded slices actually drawn — at most `sliceLimit` + "Khác".
    private var displayed: [ShareDonutSlice] { ShareDonutMath.folded(slices) }
    private var colors: [String] {
        ShareDonutMath.resolvedColorHexes(displayed, palette: AppTheme.palette)
    }
    private var percents: [Int] {
        ShareDonutMath.percents(amounts: displayed.map(\.amount))
    }
    private var total: Int64 {
        displayed.reduce(Int64(0)) {
            ShareDonutMath.saturatingAdd($0, $1.amount)
        }
    }
    private var selectedIndex: Int? {
        displayed.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 12) {
            if displayed.isEmpty || total <= 0 {
                empty
            } else {
                chart
                legend
            }
        }
    }

    // MARK: - Ring

    private var chart: some View {
        Chart {
            ForEach(Array(displayed.indices), id: \.self) { index in
                let slice = displayed[index]
                SectorMark(
                    angle: .value("Số tiền", Double(slice.amount)),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(Color(hex: colors[index]))
                .opacity(
                    selectedIndex == nil || selectedIndex == index ? 1 : 0.35
                )
                .annotation(position: .overlay) {
                    if percents[index] >= 5 {
                        Text("\(percents[index])%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0)
                    }
                }
                .accessibilityLabel(slice.name)
                .accessibilityValue(
                    "\(percents[index])%, \(VND.format(slice.amount))"
                )
            }
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $rawAngle)
        .frame(height: 190)
        .overlay { centerLabel }
        .onChange(of: rawAngle) { _, newValue in
            handleAngle(newValue)
        }
        .onChange(of: displayed.map(\.id)) { _, ids in
            // Data refreshed or mode switched: drop a stale selection.
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
                onSelect?(nil)
            }
        }
    }

    @ViewBuilder private var centerLabel: some View {
        if let index = selectedIndex {
            let slice = displayed[index]
            VStack(spacing: 2) {
                Text(slice.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(VND.compact(slice.amount))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: colors[index]))
                Text("\(percents[index])%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 44)
        } else {
            VStack(spacing: 2) {
                Text(totalTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(VND.compact(total))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.color(for: kind))
            }
        }
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(spacing: 8) {
            ForEach(Array(displayed.indices), id: \.self) { index in
                let slice = displayed[index]
                let isSelected = index == selectedIndex
                Button {
                    setSelection(isSelected ? nil : index)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: colors[index]))
                            .frame(width: 8, height: 8)
                        Text(slice.name)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        AmountText(amount: slice.amount, kind: kind, compact: true)
                            .font(.subheadline.weight(.medium))
                        Text("\(percents[index])%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(slice.name), \(percents[index])%, \(VND.format(slice.amount))"
                )
            }
        }
    }

    // MARK: - Empty

    private var empty: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 20)
                .padding(8)
            VStack(spacing: 2) {
                Text(totalTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Chưa có dữ liệu")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 190)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Selection

    /// Angle-value under the finger → slice index. Sector angles accumulate
    /// in `displayed` order, so the first slice whose running total reaches
    /// the angle is the touched one.
    private func sectorIndex(containing angle: Double) -> Int? {
        var cumulative = 0.0
        for (index, slice) in displayed.enumerated() {
            cumulative += Double(slice.amount)
            if angle <= cumulative { return index }
        }
        return nil
    }

    private func handleAngle(_ angle: Double?) {
        guard let angle else {
            touchActive = false
            return
        }
        guard let index = sectorIndex(containing: angle) else { return }
        if !touchActive {
            // Fresh touch: tapping the selected slice again deselects it.
            touchActive = true
            setSelection(index == selectedIndex ? nil : index)
        } else if index != selectedIndex {
            // Dragging across sectors moves the highlight with the finger.
            setSelection(index)
        }
    }

    private func setSelection(_ index: Int?) {
        selectedID = index.map { displayed[$0].id }
        onSelect?(index.map { displayed[$0] })
    }
}

#Preview("Donut") {
    ShareDonutChart(
        slices: [
            ShareDonutSlice(id: "a", name: "Ăn uống", amount: 4_200_000, colorHex: "FF9500"),
            ShareDonutSlice(id: "b", name: "Di chuyển", amount: 1_300_000, colorHex: "0A84FF"),
            ShareDonutSlice(id: "c", name: "Nhà cửa", amount: 950_000, colorHex: "30B0C7"),
            ShareDonutSlice(id: "d", name: "Mua sắm", amount: 700_000, colorHex: "FF2D55"),
            ShareDonutSlice(id: "e", name: "Hoá đơn", amount: 300_000, colorHex: "FF9F0A"),
            ShareDonutSlice(id: "f", name: "Chưa phân loại", amount: 120_000, colorHex: "8E8E93"),
            ShareDonutSlice(id: "g", name: "Quà tặng", amount: 80_000, colorHex: ""),
        ],
        totalTitle: "Tổng chi"
    ) { _ in }
    .padding()
}

#Preview("Trống") {
    ShareDonutChart(slices: [], totalTitle: "Tổng chi")
        .padding()
}
