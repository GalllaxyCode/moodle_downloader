import Foundation
import Testing
@testable import MoodleDownloader

private struct Stub: Sendable {
    var body: Data
    var status = 200
    var contentType = "application/pdf"
    var supportsHead = true

    init(_ text: String, status: Int = 200, contentType: String = "application/pdf", supportsHead: Bool = true) {
        body = Data(text.utf8)
        self.status = status
        self.contentType = contentType
        self.supportsHead = supportsHead
    }
}

private final class HTTPRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [URL: Stub] = [:]
    private var requests: [String] = []

    func reset(_ stubs: [URL: Stub]) {
        lock.withLock { self.stubs = stubs; requests = [] }
    }

    func takeRequests() -> [String] {
        lock.withLock { let result = requests; requests = []; return result }
    }

    func response(for request: URLRequest) -> Stub? {
        lock.withLock {
            requests.append("\(request.httpMethod ?? "GET") \(request.url!.lastPathComponent)")
            return stubs[request.url!]
        }
    }
}

private final class MockHTTP: URLProtocol, @unchecked Sendable {
    static let requests = HTTPRequests()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        guard let stub = Self.requests.response(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let status = request.httpMethod == "HEAD" && !stub.supportsHead ? 405 : stub.status
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": stub.contentType,
            "Content-Length": String(stub.body.count),
            "Content-Disposition": "attachment; filename=\"\(url.lastPathComponent)\""
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct FileDownloaderTests {
    private let course = MoodleCourse(id: "123", name: "Discrete Math", url: URL(string: "https://moodle.example.test/course/view.php?id=123")!)

    private func candidate(_ number: Int, activity: String? = nil) -> DownloadCandidate {
        DownloadCandidate(sectionIndex: 1, sectionName: "Lectures", activityName: activity ?? "Lecture \(number)",
                          url: URL(string: "https://moodle.example.test/pluginfile.php/\(number)/lecture\(number).pdf")!)
    }

    private func makeDownloader() -> FileDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        return FileDownloader(cookies: [], configuration: configuration)
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MoodleDownloaderTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func legacyFile(in root: URL, filename: String = "Lecture 1.pdf", contents: String = "week one") throws -> URL {
        let folder = root.appendingPathComponent("Discrete Math/01 — Lectures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(filename)
        try Data(contents.utf8).write(to: file)
        return file
    }

    @Test func updateDownloadsOnlyNewFilesAndRepeatsWithoutNetworkRequests() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = candidate(1), second = candidate(2)
        MockHTTP.requests.reset([first.url: Stub("week one"), second.url: Stub("week two")])
        let downloader = makeDownloader()
        let (_, initial) = try await downloader.download(candidates: [first], course: course, destination: root, makeArchive: false) { _, _, _ in }
        #expect(initial.downloaded == 1)
        #expect(MockHTTP.requests.takeRequests() == ["GET lecture1.pdf"])

        let (folder, update) = try await downloader.download(candidates: [first, second], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(update.downloaded == 1)
        #expect(update.existing == 1)
        #expect(update.skipped == 0)
        #expect(MockHTTP.requests.takeRequests() == ["HEAD lecture2.pdf", "GET lecture2.pdf"])
        #expect(try String(contentsOf: folder.appendingPathComponent("01 — Lectures/Lecture 1.pdf"), encoding: .utf8) == "week one")

        let (_, repeated) = try await makeDownloader().download(candidates: [first, second], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(repeated.downloaded == 0)
        #expect(repeated.existing == 2)
        #expect(MockHTTP.requests.takeRequests().isEmpty)
        let index = try String(contentsOf: folder.appendingPathComponent(".moodle-downloader.json"), encoding: .utf8)
        #expect(!index.contains("https:"))
    }

    @Test func adoptsOriginalAppDownloadsWithoutFetchingTheirContents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try legacyFile(in: root)
        let first = candidate(1), second = candidate(2)
        MockHTTP.requests.reset([first.url: Stub("week one"), second.url: Stub("week two")])
        let (_, summary) = try await makeDownloader().download(candidates: [first, second], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(summary.downloaded == 1)
        #expect(summary.existing == 1)
        #expect(!MockHTTP.requests.takeRequests().contains("GET lecture1.pdf"))
        #expect(try String(contentsOf: local, encoding: .utf8) == "week one")
        #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appendingPathComponent("Lecture 1 (2).pdf").path))
    }

    @Test func deletedFileIsDownloadedAgainIntoTheSelectedCourseFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = candidate(1)
        MockHTTP.requests.reset([first.url: Stub("week one")])
        let downloader = makeDownloader()
        let (folder, _) = try await downloader.download(candidates: [first], course: course, destination: root, makeArchive: false) { _, _, _ in }
        let file = folder.appendingPathComponent("01 — Lectures/Lecture 1.pdf")
        try FileManager.default.removeItem(at: file)
        _ = MockHTTP.requests.takeRequests()

        let (output, summary) = try await downloader.download(candidates: [first], course: course, destination: folder, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(output == folder)
        #expect(summary.downloaded == 1)
        #expect(MockHTTP.requests.takeRequests() == ["GET lecture1.pdf"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Discrete Math").path))
    }

    @Test func differentMaterialsWithTheSameNameAreKept() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = candidate(1), second = candidate(2, activity: "Lecture 1")
        MockHTTP.requests.reset([first.url: Stub("first pdf"), second.url: Stub("other pdf")])
        let downloader = makeDownloader()
        _ = try await downloader.download(candidates: [first], course: course, destination: root, makeArchive: false) { _, _, _ in }
        let (folder, summary) = try await downloader.download(candidates: [second, first], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(summary.downloaded == 1)
        #expect(summary.existing == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("01 — Lectures/Lecture 1 (2).pdf"), encoding: .utf8) == "other pdf")
        #expect(try String(contentsOf: folder.appendingPathComponent("01 — Lectures/Lecture 1.pdf"), encoding: .utf8) == "first pdf")
    }

    @Test func ambiguousLegacyNamesAreComparedByContent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try legacyFile(in: root, contents: "first pdf")
        let first = candidate(1), second = candidate(2, activity: "Lecture 1")
        MockHTTP.requests.reset([first.url: Stub("first pdf"), second.url: Stub("other pdf")])
        let (folder, summary) = try await makeDownloader().download(candidates: [second, first], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(summary.downloaded == 1)
        #expect(summary.existing == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("01 — Lectures/Lecture 1.pdf"), encoding: .utf8) == "first pdf")
        #expect(try String(contentsOf: folder.appendingPathComponent("01 — Lectures/Lecture 1 (2).pdf"), encoding: .utf8) == "other pdf")
    }

    @Test func unsupportedHeadDoesNotCreateDuplicateLegacyFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try legacyFile(in: root)
        let first = candidate(1)
        MockHTTP.requests.reset([first.url: Stub("week one", supportsHead: false)])
        let (_, summary) = try await makeDownloader().download(candidates: [first], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(summary.downloaded == 0)
        #expect(summary.existing == 1)
        #expect(MockHTTP.requests.takeRequests() == ["HEAD lecture1.pdf", "GET lecture1.pdf"])
    }

    @Test func failedDownloadsAndLoginPagesRemainRetryable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = candidate(1), second = candidate(2)
        MockHTTP.requests.reset([first.url: Stub("unavailable", status: 503), second.url: Stub("login", contentType: "text/html")])
        let downloader = makeDownloader()
        let (_, failed) = try await downloader.download(candidates: [first, second], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(failed.downloaded == 0)
        #expect(failed.skipped == 2)
        MockHTTP.requests.reset([first.url: Stub("week one"), second.url: Stub("week two")])
        let (_, retried) = try await downloader.download(candidates: [first, second], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(retried.downloaded == 2)
        #expect(retried.existing == 0)
    }

    @Test func cancellationKeepsCompletedDownloadsForTheNextUpdate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = candidate(1), second = candidate(2)
        let course = course
        MockHTTP.requests.reset([first.url: Stub("week one"), second.url: Stub("week two")])
        let downloader = makeDownloader()
        let task = Task {
            try await downloader.download(candidates: [first, second], course: course, destination: root, makeArchive: false, updateExisting: true) { done, _, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected the download to be cancelled")
        } catch is CancellationError { }
        _ = MockHTTP.requests.takeRequests()
        let (_, resumed) = try await makeDownloader().download(candidates: [first, second], course: course, destination: root, makeArchive: false, updateExisting: true) { _, _, _ in }
        #expect(resumed.downloaded == 1)
        #expect(resumed.existing == 1)
        #expect(!MockHTTP.requests.takeRequests().contains("GET lecture1.pdf"))
    }

    @Test func normalDownloadStillKeepsBothCopies() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = candidate(1)
        MockHTTP.requests.reset([first.url: Stub("week one")])
        let downloader = makeDownloader()
        _ = try await downloader.download(candidates: [first], course: course, destination: root, makeArchive: false) { _, _, _ in }
        let (folder, summary) = try await downloader.download(candidates: [first], course: course, destination: root, makeArchive: false) { _, _, _ in }
        #expect(summary.downloaded == 1)
        #expect(summary.existing == 0)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("01 — Lectures/Lecture 1 (2).pdf").path))
    }
}
