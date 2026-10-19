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
}
