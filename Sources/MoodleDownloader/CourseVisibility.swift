import Foundation

struct CourseVisibility {
    private let defaults: UserDefaults
    private var hiddenIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenIDs = Set(defaults.stringArray(forKey: "hiddenCourseIDs") ?? [])
    }

    func isHidden(_ course: MoodleCourse) -> Bool {
        hiddenIDs.contains(course.id)
    }

    func visibleCourses(from courses: [MoodleCourse]) -> [MoodleCourse] {
        courses.filter { !isHidden($0) }
    }

    mutating func hide(_ course: MoodleCourse) {
        hiddenIDs.insert(course.id)
        save()
    }

    mutating func show(_ course: MoodleCourse) {
        hiddenIDs.remove(course.id)
        save()
    }

    private func save() {
        defaults.set(hiddenIDs.sorted(), forKey: "hiddenCourseIDs")
    }
}
