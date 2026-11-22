import SwiftUI

/// Grid of tappable SF Symbol choices from `AppTheme.symbols`, bound to a
/// model icon string. Put it in a `Form`/`List` section of an edit form.
struct IconPickerGrid: View {
    @Binding var selection: String

    init(selection: Binding<String>) {
        _selection = selection
    }

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(AppTheme.symbols, id: \.self) { symbol in
                cell(symbol)
            }
        }
    }

    private func cell(_ symbol: String) -> some View {
        let isSelected = symbol == selection
        return Button {
            selection = symbol
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(width: 44, height: 44)
                .background(
                    isSelected ? Color.accentColor : Color(.secondarySystemFill),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    @Previewable @State var selection = "fork.knife"
    return Form {
        Section("Biểu tượng") {
            IconPickerGrid(selection: $selection)
        }
    }
}
