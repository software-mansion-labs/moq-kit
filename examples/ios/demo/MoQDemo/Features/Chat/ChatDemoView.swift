import SwiftUI

struct ChatDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ChatDemoViewModel()

    @State private var relayURL = "http://192.168.92.140:4443/anon"
    @State private var subscribePrefix = "chat"
    @State private var publishPath = "chat/ios"
    @State private var displayName = UIDevice.current.name
    @State private var draftMessage = ""

    private var canConnect: Bool {
        viewModel.canConnect
            && !relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !subscribePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publishPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        viewModel.canSend
            && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionPanel
                .padding()

            Divider()

            messageScroll

            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
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
        .onDisappear {
            viewModel.stop()
        }
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                messageList
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.messages.last?.id) {
                scrollToNewestMessage(with: proxy)
            }
            .onAppear {
                scrollToNewestMessage(with: proxy, animated: false)
            }
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Relay URL", text: $relayURL)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Subscribe Prefix", text: $subscribePrefix)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Publish Path", text: $publishPath)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Display Name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            HStack(spacing: 12) {
                Button {
                    viewModel.connect(
                        url: relayURL,
                        subscribePrefix: subscribePrefix,
                        publishPath: publishPath
                    )
                } label: {
                    Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect)

                Button {
                    viewModel.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canStop)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.stateColor)
                    .frame(width: 8, height: 8)

                Text(viewModel.stateLabel)
                    .font(.footnote.weight(.medium))

                Spacer()

                Label("\(viewModel.activeBroadcastCount)", systemImage: "bubble.left.and.bubble.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var messageList: some View {
        if viewModel.messages.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "message")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No messages")
                    .font(.headline)
                Text("Connected broadcasts with a chat track will appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary, lineWidth: 1)
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.messages) { message in
                    ChatMessageRow(message: message)
                        .id(message.id)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draftMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)

            Button {
                if viewModel.send(text: draftMessage, displayName: displayName) {
                    draftMessage = ""
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
        }
        .padding()
        .background(.bar)
    }

    private func scrollToNewestMessage(
        with proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        guard let newestMessageID = viewModel.messages.last?.id else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(newestMessageID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(newestMessageID, anchor: .bottom)
        }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isLocal {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.isLocal ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(message.from)
                        .font(.caption.weight(.semibold))

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.isLocal ? .white : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message.broadcastPath)
                    .font(.caption2)
                    .foregroundStyle(message.isLocal ? .white.opacity(0.72) : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                message.isLocal ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .frame(maxWidth: 300, alignment: message.isLocal ? .trailing : .leading)

            if !message.isLocal {
                Spacer(minLength: 40)
            }
        }
    }
}
