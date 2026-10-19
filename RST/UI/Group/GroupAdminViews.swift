import SwiftUI

// Управление группой для владельца и админов (как js/invites.js,
// js/admin-log.js и окно «Заблокированные» в modals.js).

private func shortDate(_ iso: String?) -> String {
    guard let date = ServerTime.parse(iso) else { return "" }
    return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
}

// MARK: - Ссылки и заявки

/// Ждущие заявки (принять / отклонить) и дополнительные ссылки: своё
/// название, срок, предел вступлений, через заявку; любую можно отозвать.
struct InvitesView: View {
    let chatId: String
    let keys: ChatKeys?

    @Environment(Services.self) private var services
    @State private var requests: [JoinRequestDto]?
    @State private var invites: [InviteDto]?
    @State private var error: String?
    @State private var notice: String?
    @State private var newTitle = ""
    @State private var expiresIn = 0
    @State private var limit = 0
    @State private var approval = false
    @State private var creating = false

    private static let terms: [(Int, String)] = [(0, "Без срока"), (3600, "1 час"), (86400, "1 день"), (7 * 86400, "7 дней"), (30 * 86400, "30 дней")]
    private static let limits: [(Int, String)] = [(0, "Без предела"), (1, "1 человек"), (10, "10 человек"), (50, "50 человек"), (100, "100 человек")]

    var body: some View {
        List {
            Section("Заявки на вступление") {
                if let requests {
                    if requests.isEmpty { Text("Заявок нет").foregroundStyle(Theme.muted) }
                    ForEach(requests) { r in
                        HStack(spacing: 12) {
                            AvatarView(name: r.name ?? r.username, url: r.avatarUrl, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name ?? r.username).font(.system(size: 15, weight: .medium))
                                Text(requestCaption(r)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Принять") { resolve(r, approve: true) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button { resolve(r, approve: false) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                } else {
                    ProgressView()
                }
            }

            Section {
                if let invites {
                    if invites.isEmpty { Text("Только основная ссылка группы").foregroundStyle(Theme.muted) }
                    ForEach(invites) { i in
                        VStack(alignment: .leading, spacing: 3) {
                            Text((i.title ?? "").isEmpty ? "Ссылка" : (i.title ?? ""))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(i.isActive ? Theme.onSurface : Theme.muted)
                            Text(caption(i)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        .swipeActions {
                            Button("Отозвать", role: .destructive) { revoke(i) }
                        }
                        .contextMenu {
                            if i.isActive {
                                Button { copy(i) } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                                ShareLink(item: link(i)) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                            }
                            Button(role: .destructive) { revoke(i) } label: { Label("Отозвать", systemImage: "xmark.circle") }
                        }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Дополнительные ссылки")
            } footer: {
                Text("Удерживайте ссылку, чтобы скопировать или отозвать.")
            }

            Section("Новая ссылка") {
                TextField("Название ссылки (необязательно)", text: $newTitle)
                Picker("Срок", selection: $expiresIn) {
                    ForEach(Self.terms, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Предел", selection: $limit) {
                    ForEach(Self.limits, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Вступление через заявку", isOn: $approval)
                Button("Создать ссылку") { create() }.disabled(creating)
            }

            if let error {
                Text(error).foregroundStyle(Theme.danger).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Ссылки и заявки")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .rstJoinRequestsChanged)) { note in
            if (note.object as? String) == chatId { Task { await load() } }
        }
    }

    private func link(_ i: InviteDto) -> String {
        services.groupKeys.inviteLink(base: services.api.baseURL, inviteHash: i.token, keys: keys)
    }

    private func requestCaption(_ r: JoinRequestDto) -> String {
        var line = "@\(r.username) · \(shortDate(r.createdAt))"
        if let via = r.via, !via.isEmpty { line += " · по ссылке «\(via)»" }
        return line
    }

    private func caption(_ i: InviteDto) -> String {
        let used = i.usageCount ?? 0
        var parts = [i.usageLimit.map { "вступили \(used) из \($0)" } ?? "вступили \(used)"]
        if i.state == "expired" {
            parts.append("срок истёк")
        } else if let exp = i.expiresAt, !exp.isEmpty {
            parts.append("до \(shortDate(exp))")
        }
        if i.state == "exhausted" { parts.append("предел исчерпан") }
        if i.state == "revoked" { parts.append("отозвана") }
        if i.approval == true { parts.append("через заявку") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            async let r = services.api.joinRequests(groupId: chatId)
            async let i = services.api.invites(groupId: chatId)
            requests = try await r.requests ?? []
            invites = try await i.invites ?? []
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }

    private func resolve(_ r: JoinRequestDto, approve: Bool) {
        Task {
            do {
                try await services.api.resolveJoinRequest(groupId: chatId, username: r.username, approve: approve)
                notice = approve ? "\(r.name ?? r.username) теперь в группе" : "Заявка отклонена"
            } catch {
                self.error = errorText(error)
            }
            await load()
        }
    }

    private func copy(_ i: InviteDto) {
        UIPasteboard.general.string = link(i)
        notice = "Ссылка скопирована"
    }

    private func revoke(_ i: InviteDto) {
        Task {
            do {
                try await services.api.revokeInvite(groupId: chatId, id: i.id)
                notice = "Ссылка отозвана: по ней больше не вступить"
            } catch {
                self.error = errorText(error)
            }
            await load()
        }
    }

    private func create() {
        creating = true
        var request = InviteCreateRequest()
        request.title = newTitle.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        request.expiresIn = expiresIn
        request.usageLimit = limit == 0 ? nil : limit
        request.approval = approval
        Task {
            defer { creating = false }
            do {
                let invite = try await services.api.createInvite(groupId: chatId, request)
                UIPasteboard.general.string = link(invite)
                notice = "Ссылка создана и скопирована"
                newTitle = ""
                expiresIn = 0
                limit = 0
                approval = false
            } catch {
                self.error = errorText(error)
            }
            await load()
        }
    }
}

extension Notification.Name {
    /// Пришла заявка или её рассмотрели (join_request / join_request_resolved); object — chatId.
    static let rstJoinRequestsChanged = Notification.Name("rst.joinRequestsChanged")
}

// MARK: - Заблокированные

struct GroupBansView: View {
    let chatId: String
    @Environment(Services.self) private var services
    @State private var bans: [BlockedUserDto]?
    @State private var error: String?

    var body: some View {
        List {
            if let bans {
                if bans.isEmpty { Text("Никто не заблокирован").foregroundStyle(Theme.muted) }
                ForEach(bans) { b in
                    HStack(spacing: 12) {
                        AvatarView(name: b.name ?? b.username, url: b.avatarUrl, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name ?? b.username).font(.system(size: 15, weight: .medium))
                            Text("@" + b.username).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("Разблокировать") { unban(b) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            } else {
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(Theme.danger).listRowBackground(Color.clear) }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Заблокированные")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            bans = try await services.api.groupBans(chatId).bans ?? []
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }

    private func unban(_ b: BlockedUserDto) {
        Task {
            do {
                try await services.api.unban(groupId: chatId, username: b.username)
                await load()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

// MARK: - Недавние действия

/// Журнал администраторов за 90 дней, с догрузкой.
struct AdminLogView: View {
    let chatId: String
    @Environment(Services.self) private var services
    @State private var items: [AdminLogItem] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if loaded && items.isEmpty && error == nil {
                    Text("Пока ничего не происходило").foregroundStyle(Theme.muted)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: AdminLogText.icon(item.action))
                            .foregroundStyle(AdminLogText.isDanger(item.action) ? Theme.danger : Theme.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            AdminLogText.describe(item).reduce(Text("")) { acc, part in
                                acc + Text(part.text).fontWeight(part.bold ? .semibold : .regular)
                            }
                            .font(.system(size: 14))
                            Text(shortDate(item.createdAt)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                if hasMore {
                    Button("Показать ещё") { Task { await load(more: true) } }.disabled(loading)
                }
            } footer: {
                Text("Действия администраторов за 90 дней")
            }
            if let error { Text(error).foregroundStyle(Theme.danger).listRowBackground(Color.clear) }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Недавние действия")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load(more: false) } }
        .refreshable { await load(more: false) }
    }

    private func load(more: Bool) async {
        loading = true
        defer {
            loading = false
            loaded = true
        }
        do {
            let page = try await services.api.adminLog(groupId: chatId, before: more ? items.last?.id : nil)
            let fresh = page.items ?? []
            items = more ? items + fresh : fresh
            hasMore = page.hasMore ?? false
            error = nil
        } catch {
            self.error = more ? "Не удалось загрузить" : errorText(error)
        }
    }
}

/// Текст записи журнала кусками, как describeAction в вебе: имена — жирным.
/// Неизвестное действие — «Имя: действие», чтобы новая запись не пропала.
enum AdminLogText {
    struct Part: Equatable {
        let text: String
        let bold: Bool
    }

    static func icon(_ action: String) -> String {
        if isDanger(action) { return "nosign" }
        if action.contains("pinned") { return "pin" }
        return "clock"
    }

    static func isDanger(_ action: String) -> Bool {
        ["kicked", "banned", "deleted", "revoked", "declined"].contains { action.contains($0) }
    }

    static func slowLabel(_ seconds: Int) -> String {
        if seconds >= 3600 && seconds % 3600 == 0 { return "\(seconds / 3600) ч" }
        if seconds >= 60 && seconds % 60 == 0 { return "\(seconds / 60) мин" }
        return "\(seconds) с"
    }

    private static let roles = ["admin": "администратором", "editor": "редактором", "helper": "хелпером", "member": "участником"]
    private static let timers = [86400: "через сутки", 604800: "через неделю", 2592000: "через месяц"]
    private static let fieldNames = ["name": "название", "description": "описание", "avatar_url": "аватар"]

    static func describe(_ item: AdminLogItem) -> [Part] {
        let d = item.details
        let who = Part(text: item.actorName ?? item.actor ?? "?", bold: true)
        let whom = Part(text: item.targetName ?? item.target ?? "", bold: true)
        func t(_ s: String) -> Part { Part(text: s, bold: false) }
        let on = d?["on"]?.bool == true
        let turned = on ? "включил(а)" : "выключил(а)"
        let title = d?["title"]?.string ?? ""
        let seconds = Int(d?["seconds"]?.double ?? 0)
        switch item.action {
        case "member_added": return [who, t(" добавил(а) "), whom]
        case "member_kicked": return [who, t(" исключил(а) "), whom]
        case "member_banned": return [who, t(" заблокировал(а) "), whom]
        case "member_unbanned": return [who, t(" разблокировал(а) "), whom]
        case "role_changed":
            let role = d?["role"]?.string ?? ""
            return [who, t(" назначил(а) "), whom, t(" " + (roles[role] ?? role))]
        case "owner_transferred": return [who, t(" передал(а) владение группой "), whom]
        case "title_changed":
            return title.isEmpty ? [who, t(" убрал(а) подпись у "), whom] : [who, t(" подписал(а) "), whom, t(": «\(title)»")]
        case "info_changed":
            let fields = (d?["fields"]?.array ?? []).compactMap { $0.string }.map { fieldNames[$0] ?? $0 }
            var tail = ""
            if fields.count == 1, let newName = d?["name"]?.string { tail = " на «\(newName)»" }
            let what = fields.isEmpty ? "сведения о группе" : fields.joined(separator: ", ")
            return [who, t(" изменил(а) \(what)\(tail)")]
        case "public_changed": return [who, t(on ? " сделал(а) группу публичной" : " сделал(а) группу закрытой")]
        case "protected_changed": return [who, t(on ? " запретил(а) пересылку и сохранение" : " разрешил(а) пересылку и сохранение")]
        case "admins_only_changed":
            return [who, t(on ? " разрешил(а) писать только администраторам" : " разрешил(а) писать всем участникам")]
        case "join_approval_changed": return [who, t(" \(turned) заявки на вступление")]
        case "slow_mode_changed":
            return seconds > 0 ? [who, t(" включил(а) медленный режим: раз в \(slowLabel(seconds))")] : [who, t(" выключил(а) медленный режим")]
        case "timer_changed":
            if seconds > 0 {
                let label = timers[seconds].map { " " + $0 } ?? ""
                return [who, t(" включил(а) автоудаление" + label)]
            }
            return [who, t(" выключил(а) автоудаление")]
        case "alias_changed":
            let alias = d?["alias"]?.string ?? ""
            return alias.isEmpty ? [who, t(" убрал(а) короткую ссылку")] : [who, t(" изменил(а) короткую ссылку: \(alias)")]
        case "invite_reset": return [who, t(" сбросил(а) ссылку-приглашение")]
        case "invite_created": return [who, t(title.isEmpty ? " создал(а) дополнительную ссылку" : " создал(а) ссылку «\(title)»")]
        case "invite_revoked": return [who, t(title.isEmpty ? " отозвал(а) дополнительную ссылку" : " отозвал(а) ссылку «\(title)»")]
        case "request_approved": return [who, t(" одобрил(а) заявку "), whom]
        case "request_declined": return [who, t(" отклонил(а) заявку "), whom]
        case "message_deleted": return [who, t(" удалил(а) сообщение "), whom]
        case "message_pinned": return [who, t(" закрепил(а) сообщение "), whom]
        case "message_unpinned": return [who, t(" открепил(а) сообщение "), whom]
        case "forum_changed": return [who, t(" \(turned) темы")]
        case "topic_closed":
            let closed = d?["closed"]?.bool == true
            return [who, t("\(closed ? " закрыл(а)" : " открыл(а)") тему «\(title)»")]
        case "topic_deleted": return [who, t(" удалил(а) тему «\(title)»")]
        default: return [who, t(": \(item.action)")]
        }
    }
}
