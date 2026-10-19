import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let webSession = MoodleWebSession()
    @Published var courses: [MoodleCourse] = []
    @Published var selectedCourse: MoodleCourse?
    @Published var sections: [MoodleSection] = []
    @Published var selectedSectionIDs: Set<Int> = []
    @Published var selectedActivityIDs: Set<String> = []
    @Published var state: DownloadState = .idle
    @Published var needsLogin = false
    @Published var isStarting = true
    @Published var createArchive = false
    @Published var statusMessage = "Подключаюсь к Innopolis Moodle…"
    @Published var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @Published private var courseVisibility = CourseVisibility()

    var visibleCourses: [MoodleCourse] { courseVisibility.visibleCourses(from: courses) }
    var hiddenCourses: [MoodleCourse] { courses.filter { courseVisibility.isHidden($0) } }

    private var activeTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var handledCoursesPage = false
    private var authenticationInProgress = false

    init() {
        webSession.onNavigationFinished = { [weak self] url in
            self?.navigationFinished(url)
        }
        webSession.onNavigationFailed = { [weak self] error in
            self?.isStarting = false
            self?.statusMessage = "Не удалось открыть Moodle: \(error.localizedDescription)"
        }
        Task { [weak self] in
            guard let self else { return }
            if let credentials = MoodleCredentialStore.load(),
               let loginURL = await MoodleAutoLoginService.makeLoginURL(credentials: credentials) {
                self.webSession.load(loginURL)
            } else {
                self.webSession.goHome()
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.isStarting else { return }
            self.isStarting = false
            self.statusMessage = "Moodle не ответил. Проверьте российский IP и повторите подключение."
        }
    }

    private func navigationFinished(_ url: URL) {
        isStarting = false
        if url.path.contains("/login") {
            handledCoursesPage = false
            authenticationInProgress = true
            scheduleAutomaticLogin()
            return
        }
        if url.path.contains("/my/courses") {
            loginTask?.cancel()
            authenticationInProgress = false
            needsLogin = false
            guard !handledCoursesPage else { return }
            handledCoursesPage = true
            refreshCourses()
            refreshAutologinCredentials()
        } else if authenticationInProgress {
            scheduleLoginReveal()
        }
    }

    private func refreshAutologinCredentials() {
        credentialTask?.cancel()
        credentialTask = Task { [weak self] in
            guard let self, let credentials = await self.webSession.captureMobileCredentials(), !Task.isCancelled else { return }
            MoodleCredentialStore.save(credentials)
        }
    }

    private func scheduleAutomaticLogin() {
        loginTask?.cancel()
        needsLogin = false
        isStarting = true
        loginTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let continued = await self.webSession.attemptAutomaticLogin()
            if continued {
                try? await Task.sleep(for: .seconds(5))
            } else {
                // Give Moodle/SSO cookies time to perform their own redirect before
                // exposing the browser and causing a distracting login-screen flash.
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            if self.webSession.currentURL?.path.contains("/login") == false { return }
            self.isStarting = false
            self.needsLogin = true
        }
    }

    private func scheduleLoginReveal() {
        loginTask?.cancel()
        needsLogin = false
        isStarting = true
        loginTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if self.webSession.currentURL?.path.contains("/my/courses") == true { return }
            self.isStarting = false
            self.needsLogin = true
        }
    }

    func showLoginScreen() {
        needsLogin = true
    }

    func retrySession() {
        handledCoursesPage = false
        isStarting = true
        webSession.goHome()
    }

    func refreshCourses() {
        activeTask?.cancel()
        state = .preparing("Ищу доступные курсы…")
        activeTask = Task {
            do {
                let found = try await MoodleScraper(session: webSession).loadCourses()
                try Task.checkCancellation()
                courses = found
                if selectedCourse == nil || !visibleCourses.contains(where: { $0.id == selectedCourse?.id }) {
                    selectedCourse = visibleCourses.first
                }
                statusMessage = "Найдено курсов: \(found.count)"
                state = .idle
                if let selectedCourse {
                    loadSections(for: selectedCourse)
                } else {
                    sections = []
                    clearSectionSelection()
                }
            } catch {
                if error.localizedDescription.contains("AUTH") { needsLogin = true }
                state = .failed(readable(error))
                statusMessage = readable(error)
            }
        }
    }

    func selectCourse(_ course: MoodleCourse?) {
        selectedCourse = course
        sections = []
        selectedSectionIDs = []
        selectedActivityIDs = []
        guard let course else { return }
        loadSections(for: course)
    }

    func hideCourse(_ course: MoodleCourse) {
        guard !state.isRunning else { return }
        courseVisibility.hide(course)
        if selectedCourse?.id == course.id { selectCourse(visibleCourses.first) }
    }

    func showCourse(_ course: MoodleCourse) {
        guard !state.isRunning else { return }
        courseVisibility.show(course)
        if selectedCourse == nil { selectCourse(course) }
    }

    func loadSections(for course: MoodleCourse) {
        activeTask?.cancel()
        state = .preparing("Загружаю уроки и темы…")
        activeTask = Task {
            do {
                let found = try await MoodleScraper(session: webSession).loadSections(course: course)
                try Task.checkCancellation()
                guard selectedCourse?.id == course.id else { return }
                sections = found.sorted { $0.index < $1.index }
                selectedSectionIDs = Set(found.map(\.id))
                selectedActivityIDs = Set(found.flatMap(\.activities).map(\.id))
                statusMessage = "Найдено уроков и тем: \(found.count)"
                state = .idle
            } catch is CancellationError {
                return
            } catch {
                if error.localizedDescription.contains("AUTH") { needsLogin = true }
                state = .failed("Не удалось загрузить уроки: \(readable(error))")
            }
        }
    }

    func toggleSection(_ section: MoodleSection) {
        let activityIDs = Set(section.activities.map(\.id))
        if activityIDs.isSubset(of: selectedActivityIDs) {
            selectedActivityIDs.subtract(activityIDs)
            selectedSectionIDs.remove(section.id)
        } else {
            selectedActivityIDs.formUnion(activityIDs)
            selectedSectionIDs.insert(section.id)
        }
    }

    func toggleActivity(_ activity: MoodleActivity, in section: MoodleSection) {
        if selectedActivityIDs.contains(activity.id) { selectedActivityIDs.remove(activity.id) }
        else { selectedActivityIDs.insert(activity.id) }
        let activityIDs = Set(section.activities.map(\.id))
        if activityIDs.isSubset(of: selectedActivityIDs) { selectedSectionIDs.insert(section.id) }
        else { selectedSectionIDs.remove(section.id) }
    }

    func selectedActivityCount(in section: MoodleSection) -> Int {
        section.activities.lazy.filter { self.selectedActivityIDs.contains($0.id) }.count
    }

    func selectAllSections() {
        selectedSectionIDs = Set(sections.map(\.id))
        selectedActivityIDs = Set(sections.flatMap(\.activities).map(\.id))
    }

    func clearSectionSelection() {
        selectedSectionIDs.removeAll()
        selectedActivityIDs.removeAll()
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    func exportCurrentPageHTML() {
        activeTask = Task {
            do {
                let html = try await webSession.evaluate("document.documentElement.outerHTML")
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "moodle-course-page.html"
                panel.allowedContentTypes = [.html]
                panel.prompt = "Сохранить"
                if panel.runModal() == .OK, let url = panel.url {
                    try html.write(to: url, atomically: true, encoding: .utf8)
                    statusMessage = "HTML сохранён. Перед отправкой удалите личные данные."
                }
            } catch {
                state = .failed("Не удалось сохранить HTML: \(readable(error))")
            }
        }
    }

    func startDownload(updateExisting: Bool = false) {
        guard let course = selectedCourse, !state.isRunning,
              updateExisting || !selectedActivityIDs.isEmpty else { return }
        let outputDestination = destination
        let makeArchive = !updateExisting && createArchive
        activeTask?.cancel()
        state = .preparing("Читаю структуру курса…")
        activeTask = Task {
            do {
                let scraper = MoodleScraper(session: webSession)
                let sectionsToDownload: [MoodleSection]
                if updateExisting {
                    sectionsToDownload = try await scraper.loadSections(course: course)
                    try Task.checkCancellation()
                    if selectedCourse?.id == course.id {
                        sections = sectionsToDownload.sorted { $0.index < $1.index }
                        selectAllSections()
                    }
                } else if sections.isEmpty {
                    sectionsToDownload = try await scraper.loadSections(course: course)
                        .compactMap { sectionWithSelectedActivities($0) }
                } else {
                    sectionsToDownload = sections.compactMap { sectionWithSelectedActivities($0) }
                }
                let candidates = try await discoverCandidates(in: sectionsToDownload, scraper: scraper, metadataOnly: updateExisting)
                guard !candidates.isEmpty else { throw NSError(domain: "MoodleDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "В курсе не найдено доступных для скачивания файлов."]) }
                let cookies = await webSession.cookies()
                let downloader = FileDownloader(cookies: cookies)
                let (output, summary) = try await downloader.download(candidates: candidates, course: course, destination: outputDestination, makeArchive: makeArchive, updateExisting: updateExisting) { done, total, current in
                    await MainActor.run { self.state = .downloading(done: done, total: total, current: current) }
                }
                state = .finished(output, downloaded: summary.downloaded, skipped: summary.skipped, existing: summary.existing)
                statusMessage = updateExisting
                    ? "Папка обновлена: новых файлов — \(summary.downloaded), уже есть — \(summary.existing)"
                    : "Скачано файлов: \(summary.downloaded)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch is CancellationError {
                state = .idle
                statusMessage = "Загрузка отменена."
            } catch {
                state = .failed(readable(error))
                statusMessage = readable(error)
            }
        }
    }

    func startDownloadAll() {
        let coursesToDownload = visibleCourses
        guard !coursesToDownload.isEmpty, !state.isRunning else { return }
        activeTask?.cancel()
        state = .preparing("Готовлю полный архив Moodle…")
        activeTask = Task {
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoodleDownloader-\(UUID().uuidString)", isDirectory: true)
            let staging = temporaryRoot.appendingPathComponent("Moodle Materials", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporaryRoot) }

                let scraper = MoodleScraper(session: webSession)
                var plans: [(course: MoodleCourse, candidates: [DownloadCandidate])] = []
                var skipped = 0
                for (offset, course) in coursesToDownload.enumerated() {
                    try Task.checkCancellation()
                    state = .preparing("Читаю предмет \(offset + 1) из \(coursesToDownload.count): \(course.name)")
                    do {
                        let courseSections = try await scraper.loadSections(course: course)
                        let candidates = try await discoverCandidates(
                            in: courseSections,
                            scraper: scraper,
                            messagePrefix: "\(offset + 1)/\(coursesToDownload.count)"
                        )
                        if !candidates.isEmpty { plans.append((course, candidates)) }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        skipped += 1
                    }
                }

                let total = plans.reduce(0) { $0 + $1.candidates.count }
                guard total > 0 else {
                    throw NSError(domain: "MoodleDownloader", code: 2, userInfo: [NSLocalizedDescriptionKey: "В курсах не найдено доступных для скачивания файлов."])
                }

                let cookies = await webSession.cookies()
                let downloader = FileDownloader(cookies: cookies)
                var completed = 0
                var downloaded = 0
                for plan in plans {
                    try Task.checkCancellation()
                    let base = completed
                    let (_, summary) = try await downloader.download(
                        candidates: plan.candidates,
                        course: plan.course,
                        destination: staging,
                        makeArchive: false
                    ) { done, _, current in
                        await MainActor.run {
                            self.state = .downloading(done: base + done, total: total, current: "\(plan.course.name): \(current)")
                        }
                    }
                    completed += plan.candidates.count
                    downloaded += summary.downloaded
                    skipped += summary.skipped
                }

                state = .preparing("Создаю общий ZIP-архив…")
                let output = try await downloader.archive(
                    folder: staging,
                    destination: destination,
                    filename: "Moodle Materials.zip"
                )
                state = .finished(output, downloaded: downloaded, skipped: skipped, existing: 0)
                statusMessage = "Полный архив готов: \(downloaded) файлов"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: temporaryRoot)
                state = .idle
                statusMessage = "Загрузка отменена."
            } catch {
                try? FileManager.default.removeItem(at: temporaryRoot)
                state = .failed(readable(error))
                statusMessage = readable(error)
            }
        }
    }

    private func sectionWithSelectedActivities(_ section: MoodleSection) -> MoodleSection? {
        let selected = section.activities.filter { selectedActivityIDs.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        return MoodleSection(index: section.index, name: section.name, activities: selected)
    }

    private func discoverCandidates(
        in courseSections: [MoodleSection],
        scraper: MoodleScraper,
        messagePrefix: String? = nil,
        metadataOnly: Bool = false
    ) async throws -> [DownloadCandidate] {
        var candidates: [DownloadCandidate] = []
        let totalActivities = courseSections.reduce(0) { $0 + $1.activities.count }
        var inspected = 0
        for section in courseSections {
            for activity in section.activities {
                try Task.checkCancellation()
                inspected += 1
                let prefix = messagePrefix.map { "\($0) · " } ?? ""
                state = .preparing("\(prefix)Проверяю материалы: \(inspected) из \(totalActivities)")
                let urls = try await scraper.discoverFiles(in: activity, metadataOnly: metadataOnly)
                for url in urls {
                    candidates.append(DownloadCandidate(
                        sectionIndex: section.index,
                        sectionName: section.name,
                        activityName: activity.name,
                        url: url
                    ))
                }
            }
        }
        return Array(Set(candidates)).sorted { $0.url.absoluteString < $1.url.absoluteString }
    }

    func cancel() { activeTask?.cancel() }

    private func readable(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("AUTH") { return "Сессия не авторизована. Войдите в Moodle и повторите попытку." }
        return text
    }
}
