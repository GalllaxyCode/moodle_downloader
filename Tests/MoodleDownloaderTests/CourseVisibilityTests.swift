import Foundation
import Testing
@testable import MoodleDownloader

struct CourseVisibilityTests {
    private func course(_ id: String, name: String) -> MoodleCourse {
        MoodleCourse(id: id, name: name, url: URL(string: "https://moodle.example.test/course/view.php?id=\(id)")!)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "MoodleDownloaderTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func hidingPersistsAndDoesNotDependOnTheCourseTitle() {
        withDefaults { defaults in
            let old = course("1", name: "IBC26 Discrete Math")
            let current = course("2", name: "Discrete Math")
            var visibility = CourseVisibility(defaults: defaults)
            visibility.hide(old)

            let restored = CourseVisibility(defaults: defaults)
            let renamed = course("1", name: "Archived Discrete Math")
            #expect(restored.isHidden(renamed))
            #expect(restored.visibleCourses(from: [renamed, current]) == [current])
        }
    }

    @Test func restoringOneCourseKeepsTheOthersHidden() {
        withDefaults { defaults in
            let first = course("1", name: "IBC26 Math")
            let second = course("2", name: "IBC26 Programming")
            var visibility = CourseVisibility(defaults: defaults)
            visibility.hide(first)
            visibility.hide(second)
            visibility.show(first)

            let restored = CourseVisibility(defaults: defaults)
            #expect(restored.visibleCourses(from: [first, second]) == [first])
            #expect(restored.isHidden(second))
        }
    }

    @Test func refreshPreservesHiddenCoursesAndShowsNewOnes() {
        withDefaults { defaults in
            let old = course("1", name: "IBC26 Math")
            let current = course("2", name: "Current Math")
            let new = course("3", name: "New course")
            var visibility = CourseVisibility(defaults: defaults)
            visibility.hide(old)

            #expect(visibility.visibleCourses(from: [old, current, new]) == [current, new])
            #expect(visibility.visibleCourses(from: [old]).isEmpty)
            visibility.show(old)
            #expect(visibility.visibleCourses(from: [old]) == [old])
        }
    }
}
