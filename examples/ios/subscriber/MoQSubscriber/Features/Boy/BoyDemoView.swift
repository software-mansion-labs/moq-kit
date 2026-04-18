import SwiftUI

struct BoyDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = BoyDemoViewModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.96, blue: 0.90),
                    Color(red: 0.88, green: 0.91, blue: 0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                RadialGradient(
                    colors: [
                        .white.opacity(0.45),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 40,
                    endRadius: 420
                )
            }
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                BoyConsoleView(viewModel: viewModel)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)

                Spacer(minLength: 0)
            }
        }
        .navigationTitle("Boy")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onDisappear {
            viewModel.stop()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.stop()
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }
}
