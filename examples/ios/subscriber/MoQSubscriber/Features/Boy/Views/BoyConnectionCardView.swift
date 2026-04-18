import SwiftUI

struct BoyConnectionCardView: View {
    @ObservedObject var viewModel: BoyDemoViewModel
    let onOpenConsole: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Boy console controls moved into the hardware view.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.boyLabel)

            Text(
                viewModel.isConnected
                    ? "The console is connected."
                    : "Use the power switch on the console to connect."
            )
            .font(.footnote)
            .foregroundStyle(Color.boySubLabel)

            if let lastError = viewModel.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

struct BoyStateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}
