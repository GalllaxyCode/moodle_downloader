import CryptoKit
import Foundation

actor FileDownloader {
    struct Summary { let downloaded: Int; let skipped: Int; let existing: Int }

    private struct SavedFile: Codable {
        let path: String
        let size: Int
    }

    private struct DownloadIndex: Codable {
        let courseID: String
        var files: [String: SavedFile] = [:]
    }

    private let session: URLSession
    private let fileManager = FileManager.default

    init(cookies: [HTTPCookie], configuration: URLSessionConfiguration = .default) {
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 90
        configuration.httpAdditionalHeaders = ["User-Agent": "MoodleDownloader/1.2.1 macOS"]
        cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
        session = URLSession(configuration: configuration)
    }

    func download(
        candidates: [DownloadCandidate],
        course: MoodleCourse,
        destination: URL,
        makeArchive: Bool,
        updateExisting: Bool = false,
        progress: @Sendable @escaping (Int, Int, String) async -> Void
    ) async throws -> (URL, Summary) {
        let courseName = sanitize(course.name)
        let selectedCourseFolder = destination.lastPathComponent == courseName
            || fileManager.fileExists(atPath: destination.appendingPathComponent(".moodle-downloader.json").path)
        let courseFolder = updateExisting && selectedCourseFolder
            ? destination
            : destination.appendingPathComponent(courseName, isDirectory: true)
        try fileManager.createDirectory(at: courseFolder, withIntermediateDirectories: true)
        let indexURL = courseFolder.appendingPathComponent(".moodle-downloader.json")
        var index = DownloadIndex(courseID: course.id)
        if fileManager.fileExists(atPath: indexURL.path) {
            index = try JSONDecoder().decode(DownloadIndex.self, from: Data(contentsOf: indexURL))
            guard index.courseID == course.id else {
                throw NSError(domain: "MoodleDownloader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Эта папка принадлежит другому курсу. Выберите другую папку назначения."])
            }
        }
        var claimedPaths = Set(index.files.values.map(\.path))
        // Old downloads have no index. Ambiguous names must be compared by content.
        let legacyGroups = Dictionary(grouping: candidates) {
            sectionFolderName(index: $0.sectionIndex, title: $0.sectionName)
                + "/" + smartFilename(activity: $0.activityName, serverName: "")
        }
        var downloaded = 0
        var skipped = 0
        var existing = 0

        for (offset, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            await progress(offset, candidates.count, candidate.activityName)
            let key = SHA256.hash(data: Data("\(candidate.sectionIndex):\(candidate.url.absoluteString)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            if updateExisting, let saved = index.files[key],
               let file = savedFileURL(saved, in: courseFolder), fileSize(file) == saved.size {
                existing += 1
                continue
            }

            let sectionTitle = sectionFolderName(index: candidate.sectionIndex, title: candidate.sectionName)
            let sectionFolder = courseFolder.appendingPathComponent(sectionTitle, isDirectory: true)
            do {
                var found: URL?
                let canAdopt = updateExisting && index.files[key] == nil
                let group = sectionTitle + "/" + smartFilename(activity: candidate.activityName, serverName: "")
                if canAdopt && legacyGroups[group]?.count == 1 {
                    var request = URLRequest(url: candidate.url)
                    request.httpMethod = "HEAD"
                    if let (_, response) = try? await session.data(for: request), isFileResponse(response),
                       response.expectedContentLength > 0 {
                        let filename = smartFilename(activity: candidate.activityName, serverName: suggestedFilename(response: response, url: candidate.url))
                        found = legacyFile(in: sectionFolder, filename: filename,
                                           size: Int(response.expectedContentLength), contents: nil,
                                           courseFolder: courseFolder, claimedPaths: claimedPaths)
                    }
                    try Task.checkCancellation()
                }

                let output: URL
                if let found {
                    output = found
                    existing += 1
                } else {
                    let (temporaryURL, response) = try await session.download(from: candidate.url)
                    defer { try? fileManager.removeItem(at: temporaryURL) }
                    try Task.checkCancellation()
                    guard isFileResponse(response) else { skipped += 1; continue }
                    let serverName = suggestedFilename(response: response, url: candidate.url)
                    let filename = smartFilename(activity: candidate.activityName, serverName: serverName)
                    if canAdopt, let local = legacyFile(in: sectionFolder, filename: filename,
                                                       size: fileSize(temporaryURL), contents: temporaryURL,
                                                       courseFolder: courseFolder, claimedPaths: claimedPaths) {
                        output = local
                        existing += 1
                    } else {
                        try fileManager.createDirectory(at: sectionFolder, withIntermediateDirectories: true)
                        output = uniqueURL(in: sectionFolder, filename: filename)
                        try fileManager.moveItem(at: temporaryURL, to: output)
                        downloaded += 1
                    }
                }
                let path = relativePath(output, in: courseFolder)
                index.files[key] = SavedFile(path: path, size: fileSize(output))
                claimedPaths.insert(path)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                skipped += 1
                continue
            }
            // Save after each file so an interrupted update can safely resume.
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        }
        try Task.checkCancellation()
        await progress(candidates.count, candidates.count, "Готово")
        if makeArchive {
            let archive = uniqueURL(in: destination, filename: sanitize(course.name) + ".zip")
            try zip(folder: courseFolder, to: archive)
            return (archive, Summary(downloaded: downloaded, skipped: skipped, existing: existing))
        }
        return (courseFolder, Summary(downloaded: downloaded, skipped: skipped, existing: existing))
    }

    private func isFileResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return !(http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") ?? false)
    }

    private func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true ? (values?.fileSize ?? 0) : 0
    }

    private func relativePath(_ url: URL, in folder: URL) -> String {
        // Directory listings can use /private/var while the chosen URL uses /var.
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
    }

    private func savedFileURL(_ saved: SavedFile, in folder: URL) -> URL? {
        let url = folder.appendingPathComponent(saved.path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
              fileSize(url) > 0 else { return nil }
        return url
    }

    private func legacyFile(in folder: URL, filename: String, size: Int, contents: URL?,
                            courseFolder: URL, claimedPaths: Set<String>) -> URL? {
        guard size > 0, let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let stem = NSRegularExpression.escapedPattern(for: (filename as NSString).deletingPathExtension)
        let ext = (filename as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "\\." + NSRegularExpression.escapedPattern(for: ext)
        let pattern = "^" + stem + #"(?: \([0-9]+\))?"# + suffix + "$"
        let matches = files.filter {
            !claimedPaths.contains(relativePath($0, in: courseFolder))
                && $0.lastPathComponent.range(of: pattern, options: .regularExpression) != nil
                && fileSize($0) == size
                && savedFileURL(SavedFile(path: relativePath($0, in: courseFolder), size: size), in: courseFolder) != nil
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let contents {
            return matches.first { fileManager.contentsEqual(atPath: $0.path, andPath: contents.path) }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func archive(folder: URL, destination: URL, filename: String) throws -> URL {
        let archive = uniqueURL(in: destination, filename: sanitize(filename))
        try zip(folder: folder, to: archive)
        return archive
    }

    private func suggestedFilename(response: URLResponse, url: URL) -> String {
        if let name = response.suggestedFilename, !name.isEmpty { return name }
        return url.lastPathComponent.removingPercentEncoding ?? "material"
    }

    private func smartFilename(activity: String, serverName: String) -> String {
        let ext = (serverName as NSString).pathExtension
        let cleanActivity = sanitize(activity)
        let base: String
        if let match = cleanActivity.firstMatch(of: /(?i)\b(lab(?:oratory)?|lecture|seminar|tutorial|practice|assignment)\s*[-№#:]?\s*(\d+)/) {
            let kind = String(match.1).lowercased()
            let number = String(match.2)
            let canonical: String
            if kind.hasPrefix("lab") { canonical = "Lab" }
            else if kind == "lecture" { canonical = "Lecture" }
            else if kind == "seminar" { canonical = "Seminar" }
            else if kind == "tutorial" { canonical = "Tutorial" }
            else if kind == "practice" { canonical = "Practice" }
            else { canonical = "Assignment" }
            base = "\(canonical) \(number)"
        } else {
            base = cleanActivity
        }
        guard !ext.isEmpty else { return base }
        return base.lowercased().hasSuffix("." + ext.lowercased()) ? base : base + "." + ext
    }

    private func sectionFolderName(index: Int, title: String) -> String {
        let clean = sanitize(title)
        let prefix = String(format: "%02d", max(0, index))
        if clean.range(of: #"^\d+[\s._-]"#, options: .regularExpression) != nil { return clean }
        return "\(prefix) — \(clean)"
    }

    private func sanitize(_ input: String) -> String {
        var value = input.replacingOccurrences(of: #"[/:\\?%*|\"<>]"#, with: "-", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix(".") { value.removeLast() }
        return String(value.prefix(160)).isEmpty ? "Material" : String(value.prefix(160))
    }

    private func uniqueURL(in folder: URL, filename: String) -> URL {
        var result = folder.appendingPathComponent(filename)
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var counter = 2
        while fileManager.fileExists(atPath: result.path) {
            let alternative = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            result = folder.appendingPathComponent(alternative)
            counter += 1
        }
        return result
    }

    private func zip(folder: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, archive.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
