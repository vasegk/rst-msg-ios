import SwiftUI

/// Альбом (веб: albums.js): вложения, отправленные вместе, — один пузырь.
/// Фото и видео — сеткой из рядов по 2–3, файлы — списком; время и галочки —
/// одни на альбом. Каждое вложение остаётся своим сообщением: меню на ячейке —
/// для этого вложения.
struct AlbumRow: View {
    let messages: [ChatMessage]
    let isGroup: Bool
    let isChannel: Bool
    let showSender: Bool
    let showAvatar: Bool
    let model: ChatViewModel
    var onOpenImage: (UIImage) -> Void = { _ in }
    var onForward: (ChatMessage) -> Void = { _ in }

    @Environment(ChatListStore.self) private var store

    private var first: ChatMessage { messages[0] }
    private var isMine: Bool { first.isMine }
    private var visual: [ChatMessage] {
        messages.filter { ($0.attachment?.isImage ?? false) || ($0.attachment?.isVideo ?? false) }
    }
    private var files: [ChatMessage] {
        let visualIds = Set(visual.map(\.id))
        return messages.filter { !visualIds.contains($0.id) }
    }
    /// Подпись — у первого фото/видео альбома.
    private var caption: String {
        messages.first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?.text ?? ""
    }

    /// Раскладка рядов, как в вебе: 2 → [2], 3 → [1,2], 4 → [2,2] … 10 → [2,2,3,3].
    static func rows(for count: Int) -> [Int] {
        switch count {
        case 0: return []
        case 1: return [1]
        case 2: return [2]
        case 3: return [1, 2]
        case 4: return [2, 2]
        case 5: return [2, 3]
        case 6: return [3, 3]
        case 7: return [2, 2, 3]
        case 8: return [2, 3, 3]
        case 9: return [3, 3, 3]
        default: return [2, 2, 3, 3]
        }
    }

    /// Ряды сетки из фото и видео альбома.
    private var gridRows: [[ChatMessage]] {
        var start = 0
        var rows: [[ChatMessage]] = []
        for n in Self.rows(for: visual.count) {
            let end = min(start + n, visual.count)
            if start < end { rows.append(Array(visual[start..<end])) }
            start = end
        }
        return rows
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if isGroup && !isMine && !isChannel {
                if showAvatar {
                    AvatarView(name: store.displayName(first.sender), url: store.users[first.sender]?.avatarUrl, size: 32)
                } else {
                    Color.clear.frame(width: 32, height: 1)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if showSender && isGroup && !isMine && !isChannel {
                    Text(store.displayName(first.sender))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.avatarGradient(for: store.displayName(first.sender)).0)
                }
                if !visual.isEmpty { grid }
                ForEach(files) { m in
                    if let a = m.attachment {
                        FileAttachmentView(attachment: a, isMine: isMine).contextMenu { cellMenu(m) }
                    }
                }
                if !caption.isEmpty {
                    MessageTextView(text: caption, isMine: isMine)
                }
                footer.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(6)
            .foregroundStyle(isMine ? Color.white : Theme.onSurface)
            .background(isMine ? AnyShapeStyle(Theme.ownBubble) : AnyShapeStyle(Theme.otherBubble.opacity(0.92)))
            .clipShape(BubbleShape(isMine: isMine))
            .frame(maxWidth: 290, alignment: isMine ? .trailing : .leading)
            if !isMine { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 10)
        .padding(.top, showSender ? 6 : 1)
    }

    private var grid: some View {
        let width: CGFloat = 270
        let spacing: CGFloat = 3
        return VStack(spacing: spacing) {
            ForEach(Array(gridRows.enumerated()), id: \.offset) { _, row in
                let cell = (width - spacing * CGFloat(row.count - 1)) / CGFloat(row.count)
                let height = row.count == 1 ? width * 0.62 : cell
                HStack(spacing: spacing) {
                    ForEach(row) { m in
                        cellView(m, width: cell, height: height)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cellContent(_ m: ChatMessage, width: CGFloat, height: CGFloat) -> some View {
        if let a = m.attachment, a.isImage {
            EncryptedImageView(attachment: a, maxWidth: width, maxHeight: height, onOpen: onOpenImage)
                .frame(width: width, height: height)
                .clipped()
        } else if let a = m.attachment {
            VideoAttachmentView(attachment: a)
                .frame(width: width, height: height)
                .clipped()
        }
    }

    @ViewBuilder
    private func cellView(_ m: ChatMessage, width: CGFloat, height: CGFloat) -> some View {
        // Спойлер — у каждой ячейки отдельно
        if m.spoiler {
            SpoilerContainer { cellContent(m, width: width, height: height) }
                .frame(width: width, height: height)
                .contextMenu { cellMenu(m) }
        } else {
            cellContent(m, width: width, height: height)
                .contextMenu { cellMenu(m) }
        }
    }

    @ViewBuilder
    private func cellMenu(_ m: ChatMessage) -> some View {
        if !m.pending {
            Button { model.react(m, "👍") } label: { Label("👍", systemImage: "hand.thumbsup") }
            if model.canWrite {
                Button { model.startReply(m) } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
            }
            if !model.isProtected {
                Button { onForward(m) } label: { Label("Переслать", systemImage: "arrowshape.turn.up.right") }
            }
            Divider()
            if m.isMine {
                Button(role: .destructive) { model.delete(m, forEveryone: true) } label: {
                    Label("Удалить у всех", systemImage: "trash")
                }
            }
            Button(role: .destructive) { model.delete(m, forEveryone: false) } label: {
                Label("Удалить у себя", systemImage: "trash.slash")
            }
        }
    }

    private var footer: some View {
        let last = messages[messages.count - 1]
        return HStack(spacing: 4) {
            Text(TimeFormat.clock(last.createdAt)).font(.system(size: 11))
            if isMine {
                if messages.contains(where: { $0.pending }) {
                    Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                } else {
                    Checkmarks(read: messages.allSatisfy { $0.isRead }, color: .white)
                }
            }
        }
        .padding(.horizontal, 6)
        .opacity(0.8)
    }
}
