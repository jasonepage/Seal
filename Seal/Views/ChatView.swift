import SwiftUI

/// Minimal conversation screen — proves the E2EE pipeline end to end.
/// Full ChatUI per docs/UI.md §3.3 comes after the slice is verified.
struct ChatView: View {
    let chat: ChatEngine.Chat
    let myRoot: RootIdentity
    @Bindable var engine: ChatEngine
    @State private var draft = ""

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(engine.messages(for: chat)) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                    .onChange(of: engine.messages(for: chat).count) {
                        if let last = engine.messages(for: chat).last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                if let error = engine.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    TextField("Sealed message…", text: $draft)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                    Button {
                        let text = draft.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        draft = ""
                        Task { await engine.send(text, in: chat, from: myRoot) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(SealTheme.brass)
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle(chat.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            // Poll for inbound messages while the chat is open.
            // TODO: CKSubscription push instead of polling.
            while !Task.isCancelled {
                await engine.refresh(chat, myRoot: myRoot)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatEngine.ChatMessage) -> some View {
        let mine = message.senderHash == myRoot.credentialIDHash
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .trailing, spacing: 2) {
                Text(message.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        mine ? SealTheme.brass.opacity(0.25) : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 18))
                if mine {
                    Image(systemName: message.delivered ? "checkmark.seal" : "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
    }
}
