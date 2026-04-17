import SwiftUI

struct BoyDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = BoyDemoViewModel()
    @State private var showsConsole = false

    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.95, blue: 0.91)
                .ignoresSafeArea()

            if showsConsole {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    BoyConsoleView(viewModel: viewModel)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)

                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BoyConnectionCardView(viewModel: viewModel) {
                            showsConsole = true
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                }
            }
        }
        .navigationTitle("Boy")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if showsConsole {
                        showsConsole = false
                        viewModel.closeConsole()
                    } else {
                        viewModel.stop()
                        dismiss()
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: viewModel.sessionState) { _, state in
            if state != .connected {
                showsConsole = false
            }
        }
    }
}
