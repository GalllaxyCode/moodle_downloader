import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedSectionIDs: Set<String> = []

    var body: some View {
        ZStack {
            mainInterface
                .opacity(model.needsLogin ? 0 : 1)
                .allowsHitTesting(!model.needsLogin)

            if model.needsLogin {
                loginInterface.transition(.opacity)
            } else {
                MoodleWebView(session: model.webSession)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }

            if model.isStarting { startupOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: model.needsLogin)
        .alert("Ошибка", isPresented: Binding(get: {
            if case .failed = model.state { return true }; return false
        }, set: { if !$0 { model.state = .idle } })) {
            Button("OK") { model.state = .idle }
        } message: {
            if case .failed(let message) = model.state { Text(message) }
        }
    }

    private var mainInterface: some View {
        NavigationSplitView {
            courseSidebar.navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 390)
        } detail: {
            lessonPane
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.refreshCourses() } label: {
                    Label("Обновить список курсов", systemImage: "arrow.clockwise")
                }
                .disabled(model.state.isRunning)
            }
        }
    }

    private var courseSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Moodle Downloader").font(.title2.bold())
                Text("Выберите предмет").font(.caption).foregroundStyle(.secondary)
            }

            if model.courses.isEmpty && model.state.isRunning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Загружаю предметы…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.courses.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.title).foregroundStyle(.secondary)
                    Text(model.statusMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Повторить") { model.retrySession() }
                    Button("Открыть вход") { model.showLoginScreen() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleCourses.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.title).foregroundStyle(.secondary)
                    Text("Все курсы скрыты").font(.headline)
                    Text("Верните нужный предмет через меню «Скрытые курсы» ниже.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleCourses, selection: Binding(
                    get: { model.selectedCourse },
                    set: { model.selectCourse($0) }
                )) { course in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(course.name).lineLimit(3)
                            Text("ID \(course.id)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button { model.hideCourse(course) } label: {
                            Label("Скрыть курс", systemImage: "eye.slash").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Скрыть курс")
                        .disabled(model.state.isRunning)
                    }
                    .padding(.vertical, 3)
                    .tag(course)
                    .contextMenu {
                        Button { model.hideCourse(course) } label: {
                            Label("Скрыть курс", systemImage: "eye.slash")
                        }
                        .disabled(model.state.isRunning)
                    }
                }
            }

            if !model.hiddenCourses.isEmpty {
                Menu {
                    ForEach(model.hiddenCourses) { course in
                        Button { model.showCourse(course) } label: {
                            Label(course.name, systemImage: "eye")
                        }
                    }
                } label: {
                    Label("Скрытые курсы (\(model.hiddenCourses.count))", systemImage: "eye.slash")
                }
                .help("Выберите курс, чтобы снова показать его в списке")
                .disabled(model.state.isRunning)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Сохранить в").font(.caption).foregroundStyle(.secondary)
                Button { model.chooseDestination() } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(model.destination.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                Toggle("Создать ZIP-архив", isOn: $model.createArchive)

                Button { model.startDownloadAll() } label: {
                    Label("Скачать видимые курсы одним ZIP", systemImage: "archivebox.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(model.visibleCourses.isEmpty || model.state.isRunning)
            }
        }
        .padding()
    }

    private var lessonPane: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedCourse?.name ?? "Уроки и темы")
                        .font(.title2.bold()).lineLimit(2)
                    Text(selectionDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Выбрать все") { model.selectAllSections() }.disabled(model.sections.isEmpty)
                Button("Снять выбор") { model.clearSectionSelection() }.disabled(model.sections.isEmpty)
            }
            .padding()
            Divider()

            if model.selectedCourse == nil {
                emptyPane(icon: "books.vertical", title: "Выберите предмет", detail: "После этого здесь появятся доступные уроки и темы.")
            } else if model.sections.isEmpty && model.state.isRunning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Читаю структуру курса…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sections.isEmpty {
                emptyPane(icon: "doc.questionmark", title: "Уроки не найдены", detail: "Обновите список; если ошибка повторится, откройте аккаунт и сохраните HTML курса.")
            } else {
                List {
                    ForEach(model.sections) { section in
                        DisclosureGroup(isExpanded: sectionExpansionBinding(section)) {
                            ForEach(section.activities) { activity in
                                Button { model.toggleActivity(activity, in: section) } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: model.selectedActivityIDs.contains(activity.id) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(model.selectedActivityIDs.contains(activity.id) ? Color.accentColor : .secondary)
                                        Image(systemName: activityIcon(activity.kind))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(activity.name).lineLimit(2)
                                            Text(activityKind(activity.kind)).font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 3)
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Button { model.toggleSection(section) } label: {
                                    Image(systemName: sectionSelectionIcon(section))
                                        .foregroundStyle(model.selectedActivityCount(in: section) > 0 ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help(model.selectedActivityCount(in: section) == section.activities.count
                                      ? "Снять выбор со всего занятия"
                                      : "Выбрать всё занятие")

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sectionTitle(section)).font(.headline).foregroundStyle(.primary)
                                    Text("Выбрано: \(model.selectedActivityCount(in: section)) из \(section.activities.count)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            Divider()
            downloadBar
        }
    }

    private var downloadBar: some View {
        VStack(spacing: 9) {
            if case .downloading(let done, let total, let current) = model.state {
                HStack {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("\(done) / \(total) — \(current)").font(.caption).lineLimit(1)
                    Button("Отменить") { model.cancel() }
                }
            } else if case .preparing(let text) = model.state {
                HStack { ProgressView().controlSize(.small); Text(text).font(.caption) }
            } else if case .finished(let url, let downloaded, let skipped, let existing) = model.state {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Скачано: \(downloaded)" + (existing > 0 ? ", уже есть: \(existing)" : "") + (skipped > 0 ? ", не скачано: \(skipped)" : "")).font(.caption)
                    Spacer()
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }

            HStack {
                Button { model.startDownload() } label: {
                    Label("Скачать выбранные материалы", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCourse == nil || model.selectedActivityIDs.isEmpty || model.state.isRunning)

                Button { model.startDownload(updateExisting: true) } label: {
                    Label("Обновить папку курса", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Проверить весь курс и скачать только недостающие файлы. Выберите прежнюю папку назначения или саму папку курса. ZIP не создаётся.")
                .disabled(model.selectedCourse == nil || model.state.isRunning)
            }
            .controlSize(.large)
        }
        .padding()
    }

    private var loginInterface: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Color.accentColor).font(.title2)
                VStack(alignment: .leading) {
                    Text("Вход в Innopolis Moodle").font(.headline)
                    Text("Войдите один раз — сессия сохранится на этом Mac.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.webSession.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.webSession.webView.canGoBack)
                Button { model.webSession.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { model.webSession.goHome() } label: { Image(systemName: "house") }
                Button { model.exportCurrentPageHTML() } label: { Label("Сохранить HTML", systemImage: "doc.badge.arrow.up") }
                if !model.courses.isEmpty { Button("Закрыть") { model.needsLogin = false } }
            }
            .padding()
            Divider()
            MoodleWebView(session: model.webSession)
        }
        .background(.background)
    }

    private var startupOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Открываю сохранённую сессию Moodle…").foregroundStyle(.secondary)
            }
        }
    }

    private func emptyPane(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var selectionDescription: String {
        guard !model.sections.isEmpty else { return "Выберите нужные части курса" }
        let total = model.sections.reduce(0) { $0 + $1.activities.count }
        return "Выбрано материалов: \(model.selectedActivityIDs.count) из \(total)"
    }

    private func sectionTitle(_ section: MoodleSection) -> String {
        let number = section.index > 0 ? "\(section.index). " : ""
        return number + section.name
    }

    private func sectionExpansionBinding(_ section: MoodleSection) -> Binding<Bool> {
        let key = "\(model.selectedCourse?.id ?? "none"):\(section.id)"
        return Binding(
            get: { expandedSectionIDs.contains(key) },
            set: { isExpanded in
                if isExpanded { expandedSectionIDs.insert(key) }
                else { expandedSectionIDs.remove(key) }
            }
        )
    }

    private func sectionSelectionIcon(_ section: MoodleSection) -> String {
        let selected = model.selectedActivityCount(in: section)
        if selected == 0 { return "square" }
        if selected == section.activities.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func activityKind(_ kind: String) -> String {
        switch kind.lowercased() {
        case "resource", "file": return "Файл"
        case "folder": return "Папка с файлами"
        case "page": return "Страница"
        case "url": return "Ссылка"
        case "assign": return "Задание"
        case "book": return "Книга"
        default: return kind.capitalized
        }
    }

    private func activityIcon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "folder": return "folder"
        case "url": return "link"
        case "page", "book": return "doc.text"
        case "assign": return "checklist"
        default: return "doc"
        }
    }
}
