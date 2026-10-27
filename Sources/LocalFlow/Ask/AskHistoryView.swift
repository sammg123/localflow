import SwiftUI

/// Every Ask chat, newest first and grouped by day, searchable by anything said in it.
/// A chat opens in full on the right, where it can be copied, picked back up or deleted.
struct AskHistoryView: View {
    @ObservedObject var store: AskChatStore
    @Binding var selection: AskChat.ID?
    var onContinue: (AskChat.ID) -> Void = { _ in }

    @State private var query = ""
    @State private var pendingDelete: AskChat?
    @State private var confirmDeleteAll = false

    var body: some View {
        // Searched once per update; the list and the detail share it.
        let visible = AskChatSearch.matching(store.log.chats, query: query)
        let selected = visible.first { $0.id == selection }
        NavigationSplitView {
            sidebar(visible, selected: selected)
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 380)
        } detail: {
            if let chat = selected {
                AskChatDetail(chat: chat)
                    .navigationTitle(chat.title)
                    .toolbar { actions(for: chat) }
            } else {
                ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Pick a chat on the left to read it."))
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search chats")
        // A search that hides the open chat opens the first match instead.
        .onChange(of: query) { _, _ in
            if selected == nil { selection = visible.first?.id }
        }
        .confirmationDialog("Delete this chat?", isPresented: deleteDialogShown, presenting: pendingDelete) { chat in
            Button("Delete Chat", role: .destructive) { delete(chat, from: visible) }
        } message: { _ in
            Text("It's removed from this Mac for good.")
        }
        .confirmationDialog("Delete all \(store.log.chats.count) chats?", isPresented: $confirmDeleteAll) {
            Button("Delete All Chats", role: .destructive) {
                selection = nil
                store.deleteAll()
            }
        } message: {
            Text("They're removed from this Mac for good.")
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    /// The next chat down (or up, at the end) stays open after a delete.
    private func delete(_ chat: AskChat, from visible: [AskChat]) {
        if selection == chat.id, let index = visible.firstIndex(of: chat) {
            let rest = visible.filter { $0.id != chat.id }
            selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        store.delete(chat.id)
    }

    @ViewBuilder
    private func sidebar(_ visible: [AskChat], selected: AskChat?) -> some View {
        if store.log.chats.isEmpty {
            ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Questions you ask with the Ask key show up here."))
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(selection: $selection) {
                ForEach(AskChatGroups.grouped(visible)) { group in
                    Section(group.title) {
                        ForEach(group.chats) { chat in
                            row(chat)
                                .tag(chat.id)
                                .contextMenu { menu(for: chat) }
                        }
                    }
                }
            }
            .onDeleteCommand { pendingDelete = selected }
        }
    }

    private func row(_ chat: AskChat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chat.title)
                .lineLimit(2)
            HStack(spacing: 5) {
                if store.currentChat?.id == chat.id {
                    Circle().fill(AnswerView.askBlue).frame(width: 6, height: 6)
                        .accessibilityLabel("Current chat")
                }
                Text(AskChatSearch.snippet(in: chat, query: query) ?? AskChatText.subtitle(chat))
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func menu(for chat: AskChat) -> some View {
        Button("Continue in Ask") { onContinue(chat.id) }
        Button("Copy Chat") { AskChatText.copy(chat) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = chat }
        Button("Delete All Chats…", role: .destructive) { confirmDeleteAll = true }
    }

    @ToolbarContentBuilder
    private func actions(for chat: AskChat) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Continue in Ask", systemImage: "arrowshape.turn.up.left") { onContinue(chat.id) }
                .help("Your next question picks this chat back up")
            Button("Copy Chat", systemImage: "doc.on.doc") { AskChatText.copy(chat) }
                .help("Copy every question and answer")
            Button("Delete", systemImage: "trash") { pendingDelete = chat }
                .help("Delete this chat")
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// One chat in full: each question with its answer, all of it selectable.
struct AskChatDetail: View {
    let chat: AskChat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(chat.turns) { turn in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(turn.askedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(turn.question)
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(AnswerView.askBlue.opacity(0.12))
                            )
                        ForEach(Array(AnswerFormatter.segments(turn.answer).enumerated()), id: \.offset) { _, segment in
                            segmentView(segment)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: AnswerFormatter.Segment) -> some View {
        switch segment {
        case .prose(let text):
            Text(AnswerView.inlineMarkdown(text))
                .font(.system(size: 15))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
    }
}
