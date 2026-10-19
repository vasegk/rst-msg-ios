import XCTest
@testable import RST

/// Ответы сервера, снятые со стенда (те же, на которых проверяется Android):
/// модели должны разбирать их без потерь.
final class ApiContractTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: ApiContractTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "нет файла \(name).json")
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: fixture(name))
    }

    func testContacts() throws {
        let response = try decode(ContactsResponse.self, "contacts")
        let users = try XCTUnwrap(response.users)
        XCTAssertFalse(users.isEmpty)
        let alice = try XCTUnwrap(users.first { $0.username == "alice_test" })
        XCTAssertEqual(alice.unread, 2)
        XCTAssertEqual(alice.lastMsg?.id, 9)
        XCTAssertNotNil(PackedCiphertext.parse(alice.lastMsg?.content ?? ""))
        XCTAssertNotNil(ServerTime.parse(alice.lastSeen))
        let summary = ChatSummary(user: alice)
        XCTAssertEqual(summary.chatId, "alice_test")
        XCTAssertFalse(summary.isGroup)
        for group in response.groups ?? [] {
            XCTAssertTrue(group.id.hasPrefix("group_"))
        }
    }

    func testMessages() throws {
        let response = try decode(MessagesResponse.self, "messages")
        let messages = try XCTUnwrap(response.messages)
        XCTAssertFalse(messages.isEmpty)
        XCTAssertEqual(messages.first?.id, 15)
        XCTAssertEqual(messages.first?.fileType, "application/octet-stream")
        XCTAssertNotNil(ServerTime.parse(messages.first?.createdAt))
        XCTAssertEqual(MessageRepository.parseReactions(messages.first?.reactions), [:])
    }

    func testGroupMessages() throws {
        let response = try decode(MessagesResponse.self, "gmessages")
        XCTAssertNotNil(response.messages)
    }

    func testGroupInfo() throws {
        let info = try decode(GroupInfoResponse.self, "group_info")
        XCTAssertFalse(info.members?.isEmpty ?? true)
        XCTAssertNotNil(info.members?.first?.role)
    }

    func testKeysLimitsFolders() throws {
        _ = try decode(KeysResponse.self, "keys")
        let limits = try decode(LimitsResponse.self, "limits")
        XCTAssertGreaterThan(limits.maxUploadBytes ?? 0, 0)
        _ = try decode(FoldersResponse.self, "folders")
        _ = try decode(GroupKeyResponse.self, "group_key")
        _ = try decode(ChatTimerResponse.self, "timer")
        _ = try decode(RecoveryStatusResponse.self, "recovery_status")
    }

    func testListsDecode() throws {
        _ = try decode(SessionsResponse.self, "sessions")
        _ = try decode(UsersSearchResponse.self, "search")
        _ = try decode(GroupsSearchResponse.self, "group_search")
        _ = try decode(PinnedResponse.self, "pinned")
        _ = try decode(MediaResponse.self, "media")
        _ = try decode(BlockedResponse.self, "blocked")
        _ = try decode(GroupBansResponse.self, "group_bans")
        let shared = try decode(SharedResponse.self, "shared")
        XCTAssertNotNil(shared.sharedGroups)
        _ = try decode(SharedResponse.self, "shared_blocked")
    }

    func testServerTimeFormats() {
        XCTAssertNotNil(ServerTime.parse("2026-10-01T23:08:43.258517"))
        XCTAssertNotNil(ServerTime.parse("2026-10-01T23:08:43Z"))
        XCTAssertNotNil(ServerTime.parse("2026-10-01T23:08:43.123+03:00"))
        XCTAssertNil(ServerTime.parse(nil))
        XCTAssertNil(ServerTime.parse(""))
        // Без пояса — это UTC
        let a = ServerTime.parse("2026-10-01T10:00:00")
        let b = ServerTime.parse("2026-10-01T10:00:00Z")
        XCTAssertEqual(a, b)
    }

    func testValidationErrorText() {
        let body = #"{"detail":[{"loc":["body","display_name"],"msg":"bad","type":"value_error"}]}"#
        XCTAssertEqual(ApiErrorText.detail(Data(body.utf8), code: 422), "Проверьте поле «Имя»")
        XCTAssertEqual(ApiErrorText.detail(Data(#"{"detail":"Неверный пароль"}"#.utf8), code: 400), "Неверный пароль")
        XCTAssertEqual(ApiErrorText.detail(Data("<html>".utf8), code: 413), "Файл слишком большой")
    }

    func testNewMessageEventDecodes() throws {
        let raw = #"{"action":"new_msg","id":"42","sender":"ivan","receiver":"group_3","content":"{\"iv\":\"a\",\"ciphertext\":\"b\"}","file_url":null,"file_type":null,"status":"sent","reactions":{"bob":"👍"},"is_edited":false,"reply_to":null,"created_at":"2026-10-01T10:00:00","poll":{"options":2,"counts":[1,0],"my":[0]}}"#
        let value = try XCTUnwrap(JSONValue.parse(raw))
        let dto = try XCTUnwrap(value.decode(MessageDto.self))
        XCTAssertEqual(dto.id, 42)
        XCTAssertEqual(dto.receiver, "group_3")
        XCTAssertEqual(MessageRepository.parseReactions(dto.reactions), ["bob": "👍"])
        let poll = try XCTUnwrap(PollState(dto.poll))
        XCTAssertEqual(poll.counts, [1, 0])
        XCTAssertEqual(poll.my, [0])
    }

    /// set_view из routers/stickers.py и подписи, как в js/stickers.js.
    func testStickerSetDecodesAndHelpers() throws {
        let raw = #"{"sets":[{"id":7,"name":"cats","title":"Коты","mine":false,"installed":true,"stickers":[{"id":1,"file_url":"/uploads/0123456789abcdef0123456789abcdef.webp","emoji":"😺"}]}]}"#
        let sets = try JSONDecoder().decode(StickerSetsResponse.self, from: Data(raw.utf8)).sets ?? []
        XCTAssertEqual(sets.first?.stickers.first?.fileUrl, "/uploads/0123456789abcdef0123456789abcdef.webp")
        XCTAssertEqual(sets.first?.installed, true)
        XCTAssertEqual(StickerStore.caption("😺"), "😺 Стикер")
        XCTAssertEqual(StickerStore.caption(""), "Стикер")
        XCTAssertEqual(StickerStore.suggestName("Мои коты!"), "moi_koty")
        XCTAssertTrue(StickerStore.isValidName("moi_koty"))
        XCTAssertFalse(StickerStore.isValidName("ab"))
        XCTAssertEqual(StickerStore.countText(1), "1 стикер")
        XCTAssertEqual(StickerStore.countText(3), "3 стикера")
        XCTAssertEqual(StickerStore.countText(12), "12 стикеров")
        let body = try JSONCoding.encodeData(StickerAddRequest(fileUrl: "/uploads/a.png", emoji: "🙂"))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#""file_url":"/uploads/a.png""#))
    }

    /// Журнал администраторов (describeAction в js/admin-log.js) и ссылки-приглашения.
    func testAdminLogAndInvites() throws {
        let raw = #"{"items":[{"id":5,"action":"slow_mode_changed","created_at":"2026-10-19T10:00:00","actor":"ivan","actor_name":"Иван","target":null,"target_name":null,"details":{"seconds":300}},{"id":4,"action":"title_changed","actor":"ivan","actor_name":"Иван","target":"bob","target_name":"Боб","details":{"title":"Модератор"}},{"id":3,"action":"brand_new","actor":"ivan","details":{}}],"has_more":true}"#
        let page = try JSONDecoder().decode(AdminLogResponse.self, from: Data(raw.utf8))
        XCTAssertEqual(page.hasMore, true)
        let items = try XCTUnwrap(page.items)
        XCTAssertEqual(AdminLogText.describe(items[0]).map(\.text).joined(), "Иван включил(а) медленный режим: раз в 5 мин")
        XCTAssertEqual(AdminLogText.describe(items[1]).map(\.text).joined(), "Иван подписал(а) Боб: «Модератор»")
        XCTAssertEqual(AdminLogText.describe(items[1]).first?.bold, true)
        XCTAssertEqual(AdminLogText.describe(items[2]).map(\.text).joined(), "ivan: brand_new")

        var request = InviteCreateRequest()
        request.title = "Для друзей"
        request.approval = true
        let body = String(decoding: try JSONCoding.encodeData(request), as: UTF8.self)
        XCTAssertTrue(body.contains(#""usage_limit":null"#))
        XCTAssertTrue(body.contains(#""expires_in":0"#))

        let invites = #"{"invites":[{"id":1,"token":"abc","title":"","created_by":"ivan","created_at":"2026-10-19T10:00:00","expires_at":null,"usage_limit":10,"usage_count":2,"approval":false,"state":"exhausted"}],"join_approval":true,"requests":3}"#
        let list = try JSONDecoder().decode(InvitesResponse.self, from: Data(invites.utf8))
        XCTAssertEqual(list.requests, 3)
        XCTAssertEqual(list.invites?.first?.isActive, false)
    }

    /// list_topics из routers/topics.py: «Общее» первым, last_msg без receiver.
    func testTopicsDecode() throws {
        let raw = #"{"forum":true,"can_manage":false,"can_create":true,"topics":[{"id":0,"title":"Общее","icon":"","closed":false,"general":true,"created_by":null,"last_msg":null,"unread":0},{"id":7,"title":"Игры","icon":"🎮","closed":true,"general":false,"created_by":"ivan","last_msg":{"id":"55","sender":"ivan","content":"{\"iv\":\"a\",\"ciphertext\":\"b\"}","file_type":null,"file_url":null,"time":"2026-10-19T10:00:00"},"unread":3}]}"#
        let page = try JSONDecoder().decode(TopicsResponse.self, from: Data(raw.utf8))
        let topics = try XCTUnwrap(page.topics)
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics[0].topic.general, true)
        XCTAssertEqual(topics[1].topic, ForumTopic(id: 7, title: "Игры", icon: "🎮", closed: true, general: false))
        XCTAssertEqual(topics[1].lastMsg?.id, 55)
        XCTAssertEqual(topics[1].unread, 3)
        XCTAssertEqual(topics[1].lastTime, "2026-10-19T10:00:00")
        XCTAssertEqual(CommentsSheet.countText(21), "21 комментарий")
        XCTAssertEqual(CommentsSheet.countText(5), "5 комментариев")
    }

    /// Этап D: отсчёт блокировки, день рождения, подпись истории аватаров, музыка в профиле.
    func testProfileExtras() throws {
        XCTAssertEqual(ModerationText.remaining(2 * 86400 + 3 * 3600 + 5), "2 дня 3 часа")
        XCTAssertEqual(ModerationText.remaining(14 * 60 + 5), "14 минут 5 секунд")
        XCTAssertEqual(ModerationText.remaining(21), "21 секунда")
        XCTAssertEqual(ModerationText.remaining(3600 + 60), "1 час 1 минута")

        let now = try XCTUnwrap(ServerTime.parse("2026-10-19T12:00:00"))
        let today = Calendar.current.dateComponents([.month, .day], from: now)
        XCTAssertTrue(ConfettiView.isToday(String(format: "1990-%02d-%02d", today.month!, today.day!), now: now))
        XCTAssertFalse(ConfettiView.isToday("1990-01-01", now: now))
        XCTAssertFalse(ConfettiView.isToday(nil, now: now))

        XCTAssertEqual(AvatarHistoryViewer.dateLabel(nil), "")
        XCTAssertTrue(AvatarHistoryViewer.dateLabel("2020-03-05T10:00:00", now: now).hasSuffix("2020"))

        var request = ProfileUpdateRequest(username: "ivan")
        request.musicUrl = ""
        request.musicTitle = ""
        let body = String(decoding: try JSONCoding.encodeData(request), as: UTF8.self)
        XCTAssertTrue(body.contains("\"music_url\":\"\""))
        let avatars = #"{"avatars":[{"url":"/uploads/a.jpg","set_at":null},{"url":"/uploads/b.jpg","set_at":"2026-01-02T03:04:05"}]}"#
        let list = try JSONDecoder().decode(AvatarsResponse.self, from: Data(avatars.utf8)).avatars ?? []
        XCTAssertEqual(list.count, 2)
        XCTAssertNil(list[0].setAt)
    }

    /// Цвет оформления — формулы js/accent-colors.js (ярко-жёлтый становится оливковым #adad0b).
    func testAccentMath() {
        XCTAssertEqual(AccentMath.readable("#ffff00").hex, "#adad0b")
        XCTAssertTrue(AccentMath.readable("#ffff00").darkened)
        XCTAssertEqual(AccentMath.readable("#2f7ff0").hex, "#2f7ff0")
        XCTAssertFalse(AccentMath.readable("#2f7ff0").darkened)
        XCTAssertEqual(AccentMath.parse("#F57C00"), 0xF57C00)
        XCTAssertNil(AccentMath.parse("orange"))
        XCTAssertNotEqual(AccentMath.lighter("#2f7ff0"), "#2f7ff0")
    }

    /// Экспорт переписки: запись как formatExportMessage в js/chat-export.js.
    func testChatExportFormat() {
        var m = ChatMessage(id: 1, sender: "ivan", isMine: false, text: "Привет
как дела", createdAt: nil)
        m.forwardedFrom = "bob"
        m.isEdited = true
        let text = ChatExport.format(m) { $0 == "ivan" ? "Иван" : $0 }
        XCTAssertEqual(text, "[] Иван:
    (переслано от bob)
    Привет
    как дела
    (изменено)")
        XCTAssertEqual(ChatExport.safeFilePart("Мой чат: тест"), "Мой_чат_тест")
        XCTAssertEqual(ChatExport.messagesWord(21), "сообщение")
    }
}
