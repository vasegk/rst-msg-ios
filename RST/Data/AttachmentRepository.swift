import Foundation
import UIKit
import UniformTypeIdentifiers

/// Вложения: шифрование и загрузка, скачивание и расшифровка с кешем.
///
/// Расшифрованное лежит в памяти (NSCache) и, для просмотра и «Поделиться»,
/// во временной папке приложения; при выходе из аккаунта папка стирается.
@MainActor
final class AttachmentRepository {
    private let api: RstApi
    private let memory = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    var maxUploadBytes: Int64 = RstApi.defaultMaxUploadBytes

    init(api: RstApi) {
        self.api = api
        memory.totalCostLimit = 150 * 1024 * 1024
    }

    var maxPlainBytes: Int64 { maxUploadBytes - RstApi.attachmentOverhead }

    static var tempDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rst-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Uploaded {
        let fileUrl: String
        let keyB64: String
    }

    /// Шифрует файл своим случайным ключом и загружает как attachment.enc.
    func upload(_ plain: Data) async throws -> Uploaded {
        guard Int64(plain.count) <= maxPlainBytes else {
            throw CryptoError("Файл больше \(ByteCountFormatter.string(fromByteCount: maxPlainBytes, countStyle: .file))")
        }
        let encrypted = try await Task.detached(priority: .userInitiated) { try FileCrypto.encrypt(plain) }.value
        let response = try await api.upload(encrypted.payload, fileName: RstApi.attachmentFileName, mimeType: RstApi.attachmentMime)
        memory.setObject(plain as NSData, forKey: response.fileUrl as NSString, cost: plain.count)
        return Uploaded(fileUrl: response.fileUrl, keyB64: encrypted.keyB64)
    }

    /// Аватары и обложки не шифруются: их видят люди без общего ключа.
    func uploadPlain(_ data: Data, fileName: String, mimeType: String) async throws -> String {
        try await api.upload(data, fileName: fileName, mimeType: mimeType).fileUrl
    }

    /// Скачать и расшифровать; повторные запросы того же файла ждут первый.
    func data(for attachment: Attachment) async throws -> Data {
        let key = attachment.fileUrl as NSString
        if let cached = memory.object(forKey: key) { return cached as Data }
        if let running = inFlight[attachment.fileUrl] { return try await running.value }
        let api = self.api
        let task = Task<Data, Error> {
            let payload = try await api.download(attachment.fileUrl)
            return try await Task.detached(priority: .userInitiated) {
                try FileCrypto.decrypt(payload, keyB64: attachment.fileKeyB64)
            }.value
        }
        inFlight[attachment.fileUrl] = task
        defer { inFlight[attachment.fileUrl] = nil }
        let plain = try await task.value
        memory.setObject(plain as NSData, forKey: key, cost: plain.count)
        return plain
    }

    private func localURL(for attachment: Attachment) -> URL {
        let digest = Data(RstCrypto.sha256(Data(attachment.fileUrl.utf8)).prefix(8)).hexString
        return Self.tempDir.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(Self.safeName(attachment))
    }

    /// Уже расшифрованный на диск файл, если есть.
    func existingFileURL(for attachment: Attachment) -> URL? {
        let url = localURL(for: attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Файл на диске для просмотра, проигрывания и «Поделиться».
    func fileURL(for attachment: Attachment) async throws -> URL {
        let url = localURL(for: attachment)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let plain = try await data(for: attachment)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plain.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Картинка без шифрования (стикер, аватар) — по ссылке сервера.
    func plainData(_ fileUrl: String) async throws -> Data {
        let key = ("plain:" + fileUrl) as NSString
        if let cached = memory.object(forKey: key) { return cached as Data }
        let data = try await api.download(fileUrl)
        memory.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    func clear() {
        memory.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: Self.tempDir)
    }

    private static func safeName(_ a: Attachment) -> String {
        var name = a.fileName.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        if name.isEmpty || name == "файл" { name = "file" }
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(mimeType: a.mimeType)?.preferredFilenameExtension {
            name += "." + ext
        }
        return name
    }

    // MARK: - Подготовка фото

    /// Фото перед отправкой: длинная сторона до 2560, JPEG 0.85 — как сжатие в вебе.
    nonisolated static func compressImage(_ data: Data, maxSide: CGFloat = 2560, quality: CGFloat = 0.85) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }

    nonisolated static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext.lowercased())?.preferredMIMEType ?? "application/octet-stream"
    }
}
