import SwiftUI

/// Grid of tappable color swatches from `AppTheme.palette`, bound to a model
/// `colorHex` string ("RRGGBB"). Put it in a `Form`/`List` section of an
/// edit form.
struct ColorHexPickerGrid: View {
    @Binding var selection: String

    init(selection: Binding<String>) {
        _selection = selection
    }

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(AppTheme.palette, id: \.self) { hex in
                cell(hex)
            }
        }
    }

    private func cell(_ hex: String) -> some View {
        let isSelected = hex.uppercased() == selection.uppercased()
        return Button {
            selection = hex
        } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 32, height: 32)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Màu \(hex)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    @Previewable @State var selection = "0A84FF"
    return Form {
        Section("Màu sắc") {
            ColorHexPickerGrid(selection: $selection)
        }
    }
}
