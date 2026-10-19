import Foundation
import WebKit

enum ScraperError: LocalizedError {
    case invalidResult
    case notAuthenticated
    case noCourses

    var errorDescription: String? {
        switch self {
        case .invalidResult: "Moodle вернул неожиданный формат страницы."
        case .notAuthenticated: "Сначала войдите в Moodle в окне приложения."
        case .noCourses: "Курсы не найдены. Откройте страницу «Мои курсы» и попробуйте ещё раз."
        }
    }
}

@MainActor
final class MoodleScraper {
    private let session: MoodleWebSession

    init(session: MoodleWebSession) { self.session = session }

    func loadCourses() async throws -> [MoodleCourse] {
        let script = #"""
        (async () => {
          if (location.pathname.includes('/login/')) throw new Error('AUTH');

          // Moodle's Course overview inserts cards asynchronously. A second fetch of
          // /my/courses.php only returns the empty template, so inspect the live DOM.
          for (let attempt = 0; attempt < 20; attempt++) {
            if (document.querySelector('[data-region="course-content"][data-course-id], .course-card[data-course-id]')) break;
            await new Promise(resolve => setTimeout(resolve, 250));
          }

          const map = new Map();
          const cards = [...document.querySelectorAll(
            '[data-region="course-content"][data-course-id], .course-card[data-course-id]'
          )];
          for (const card of cards) {
            const a = card.querySelector('a.coursename[href*="/course/view.php?id="], a[href*="/course/view.php?id="]');
            if (!a) continue;
            const u = new URL(a.href, location.origin);
            const id = card.dataset.courseId || u.searchParams.get('id');
            if (!id) continue;
            const multiline = card.querySelector('.multiline');
            let name = (
              multiline?.getAttribute('title') ||
              multiline?.querySelector('[aria-hidden="true"]')?.textContent ||
              a.getAttribute('title') ||
              a.textContent || ''
            ).replace(/\s+/g, ' ').trim();
            if (!name || name.length < 2) continue;
            map.set(String(id), {id: String(id), name, url: u.href});
          }

          // Fallback for list-style course views and older Moodle themes.
          if (!map.size) {
            const anchors = [...document.querySelectorAll('a[href*="/course/view.php?id="]')];
            for (const a of anchors) {
              const u = new URL(a.href, location.origin);
              const id = u.searchParams.get('id');
              if (!id) continue;
              const multiline = a.querySelector('.multiline');
              const name = (multiline?.getAttribute('title') || a.textContent || '').replace(/\s+/g, ' ').trim();
              if (name.length >= 2 && (!map.has(id) || name.length > map.get(id).name.length)) {
                map.set(id, {id, name, url: u.href});
              }
            }
          }
          return JSON.stringify([...map.values()]);
        })()
        """#
        let json = try await session.evaluate(script)
        guard let data = json.data(using: .utf8) else { throw ScraperError.invalidResult }
        let scraped = try JSONDecoder().decode([ScrapedCourse].self, from: data)
        let courses = scraped.compactMap { item -> MoodleCourse? in
            guard let url = URL(string: item.url) else { return nil }
            return MoodleCourse(id: item.id, name: item.name, url: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if courses.isEmpty { throw ScraperError.noCourses }
        return courses
    }

    func loadSections(course: MoodleCourse) async throws -> [MoodleSection] {
        let url = jsQuote(course.url.absoluteString)
        let script = #"""
        (async () => {
          const response = await fetch(\#(url), {credentials: 'include'});
          if (!response.ok || response.url.includes('/login/')) throw new Error('AUTH');
          const html = await response.text();
          const doc = new DOMParser().parseFromString(html, 'text/html');
          let sectionNodes = [...doc.querySelectorAll('li.section, [data-sectionid].section, .course-section')];
          if (!sectionNodes.length) sectionNodes = [doc.querySelector('main') || doc.body];
          return JSON.stringify(sectionNodes.map((section, position) => {
            // data-sectionid is a database id, not the lesson number shown to users.
            const rawIndex = section.dataset.number || position;
            const heading = section.querySelector('.sectionname, .section-title, h2, h3');
            const name = (heading?.textContent || `Section ${position}`).replace(/\s+/g, ' ').trim();
            const seen = new Set();
            const activities = [];
            const anchors = [...section.querySelectorAll(
              '.activity a[href], a.aalink[href], a[href*="/mod/resource/"], a[href*="/mod/folder/"], a[href*="/pluginfile.php/"]'
            )];
            for (const a of anchors) {
              const u = new URL(a.href, location.origin);
              if (seen.has(u.href) || u.href.startsWith('javascript:')) continue;
              const row = a.closest('.activity') || a;
              const titleNode = row.querySelector?.('.instancename, .activityname, .aalink') || a;
              let activityName = (titleNode.textContent || a.getAttribute('title') || 'Material').replace(/\s+/g, ' ').trim();
              activityName = activityName.replace(/\s*(File|Folder|URL|Page)$/i, '').trim() || 'Material';
              const match = u.pathname.match(/\/mod\/([^/]+)\//);
              const kind = match ? match[1] : (u.pathname.includes('pluginfile.php') ? 'file' : 'link');
              seen.add(u.href);
              activities.push({name: activityName, url: u.href, kind});
            }
            return {index: Number(rawIndex) || position, name, activities};
          }).filter(s => s.activities.length));
        })()
        """#
        let json = try await session.evaluate(script)
        guard let data = json.data(using: .utf8) else { throw ScraperError.invalidResult }
        let raw = try JSONDecoder().decode([ScrapedSection].self, from: data)
        return raw.map { section in
            MoodleSection(index: section.index, name: section.name, activities: section.activities.compactMap {
                guard let url = URL(string: $0.url) else { return nil }
                return MoodleActivity(name: $0.name, url: url, kind: $0.kind)
            })
        }
    }

    func discoverFiles(in activity: MoodleActivity, metadataOnly: Bool = false) async throws -> [URL] {
        if activity.url.path.contains("pluginfile.php") { return [activity.url] }
        let quoted = jsQuote(activity.url.absoluteString)
        let script = #"""
        (async () => {
          const options = {credentials: 'include', redirect: 'follow'};
          const metadataOnly = \#(metadataOnly ? "true" : "false");
          let response = await fetch(\#(quoted), {...options, method: metadataOnly ? 'HEAD' : 'GET'});
          // Resource pages redirect to the file itself. Resolve that URL without
          // downloading its body; only HTML pages need a full fetch to find links.
          if (metadataOnly && (!response.ok || (
            (response.headers.get('content-type') || '').includes('text/html') &&
            !/attachment/i.test(response.headers.get('content-disposition') || '')
          ))) response = await fetch(\#(quoted), options);
          const type = response.headers.get('content-type') || '';
          const disposition = response.headers.get('content-disposition') || '';
          if (!type.includes('text/html') || /attachment/i.test(disposition)) return JSON.stringify([response.url]);
          const html = await response.text();
          const doc = new DOMParser().parseFromString(html, 'text/html');
          const found = new Set();
          for (const a of doc.querySelectorAll('a[href]')) {
            const u = new URL(a.href, response.url);
            if (u.pathname.includes('pluginfile.php') && !u.pathname.includes('/theme_') && !u.pathname.includes('/user/')) found.add(u.href);
          }
          return JSON.stringify([...found]);
        })()
        """#
        let json = try await session.evaluate(script)
        guard let data = json.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([String].self, from: data).compactMap(URL.init(string:))
    }

    private func jsQuote(_ string: String) -> String {
        let data = try? JSONEncoder().encode(string)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
