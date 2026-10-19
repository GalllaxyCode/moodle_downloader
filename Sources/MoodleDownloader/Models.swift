import Foundation

struct MoodleCourse: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let url: URL
}

struct MoodleSection: Identifiable, Codable, Hashable {
    let index: Int
    let name: String
    let activities: [MoodleActivity]

    var id: Int { index }
}

struct MoodleActivity: Identifiable, Codable, Hashable {
    let name: String
    let url: URL
    let kind: String

    var id: String { url.absoluteString }
}

struct DownloadCandidate: Hashable {
    let sectionIndex: Int
    let sectionName: String
    let activityName: String
    let url: URL
}

enum DownloadState: Equatable {
    case idle
    case preparing(String)
    case downloading(done: Int, total: Int, current: String)
    case finished(URL, downloaded: Int, skipped: Int, existing: Int)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .preparing, .downloading: true
        default: false
        }
    }
}

struct ScrapedCourse: Decodable {
    let id: String
    let name: String
    let url: String
}

struct ScrapedSection: Decodable {
    let index: Int
    let name: String
    let activities: [ScrapedActivity]
}

struct ScrapedActivity: Decodable {
    let name: String
    let url: String
    let kind: String
}
