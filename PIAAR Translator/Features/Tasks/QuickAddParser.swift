import Foundation

struct QuickAddParseResult: Equatable {
    let originalText: String
    var title: String
    var scheduledDate: TaskDay
    var scheduledAt: Date?
    var dayPeriod: TaskDayPeriod?
    var estimatedMinutes: Int?
    var priority: TaskPriority = .normal
    var recognizedTokens: [String] = []
    var preview: [String] = []
    func draft(groupID: UUID? = nil) -> TaskDraft {
        TaskDraft(title: title, scheduledDate: scheduledDate, groupID: groupID,
                  scheduledAt: scheduledAt, dayPeriod: dayPeriod, estimatedMinutes: estimatedMinutes, priority: priority)
    }
}

// All matches refer to the original UTF-16 ranges; consumed/protected tokens never overlap.
// Unknown, ambiguous or invalid expressions are preserved verbatim in the title.
enum QuickAddParser {
    static func parse(_ input: String, referenceDate: Date, calendar supplied: Calendar,
                      timeZone: TimeZone, defaultDate: TaskDay? = nil) -> QuickAddParseResult {
        var calendar = supplied; calendar.timeZone = timeZone
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: referenceDate)
        let source = input as NSString
        var result = QuickAddParseResult(originalText: input, title: input, scheduledDate: defaultDate ?? TaskDay(today, calendar: calendar))
        var used: [NSRange] = [], protected: [NSRange] = []
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern)).map { $0.matches(in: input, range: NSRange(location: 0, length: source.length)) } ?? []
        }
        func text(_ m: NSTextCheckingResult, _ i: Int = 0) -> String {
            let range = m.range(at: i); return range.location == NSNotFound ? "" : source.substring(with: range)
        }
        func free(_ range: NSRange) -> Bool { !(used + protected).contains { NSIntersectionRange($0, range).length > 0 } }
        func consume(_ m: NSTextCheckingResult) { used.append(m.range); result.recognizedTokens.append(text(m)) }
        protected = matches("(?:매주\\s*[월화수목금토일]요일|매일|평일마다|매월\\s*\\d+일|매달\\s*마지막\\s*날)").map(\.range)
        let edge = "(?<![\\p{L}\\p{N}])"
        let tail = "(?![\\p{L}\\p{N}])"
        var dateCandidates: [(NSTextCheckingResult, Date)] = []
        for m in matches(edge + "(\\d{1,2})(?:월\\s*|[/.])(\\d{1,2})(?:일)?" + tail) where free(m.range) {
            guard let month = Int(text(m, 1)), let day = Int(text(m, 2)), (1...12).contains(month), (1...31).contains(day) else { continue }
            let year = calendar.component(.year, from: today)
            for y in year...(year + 8) {
                guard let candidate = calendar.date(from: DateComponents(year: y, month: month, day: day)),
                      calendar.component(.month, from: candidate) == month, calendar.component(.day, from: candidate) == day, candidate >= today else { continue }
                dateCandidates.append((m, candidate)); break
            }
        }
        for m in matches(edge + "(오늘|내일|모레|일주일\\s*뒤|\\d+\\s*(?:일|주)\\s*뒤)" + tail) where free(m.range) {
            let t = text(m).replacingOccurrences(of: " ", with: "")
            let amount: Int
            if t == "오늘" { amount = 0 } else if t == "내일" { amount = 1 } else if t == "모레" { amount = 2 }
            else if t == "일주일뒤" { amount = 7 }
            else {
                let multiplier = t.contains("주") ? 7 : 1
                guard let number = Int(t.prefix { $0.isNumber }), (1...(3650 / multiplier)).contains(number) else { continue }
                amount = number * multiplier
            }
            guard (0...3650).contains(amount), let date = calendar.date(byAdding: .day, value: amount, to: today) else { continue }
            dateCandidates.append((m, date))
        }
        for m in matches(edge + "(?:(이번\\s*주|다음\\s*주)\\s*)?([월화수목금토일])요일" + tail) where free(m.range) {
            let weekday = ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7][text(m, 2)]!
            let week = text(m, 1)
            let base: Date; let offset: Int
            if week.isEmpty { base = today; offset = (weekday - calendar.component(.weekday, from: today) + 7) % 7 }
            else {
                guard let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { continue }
                base = start; offset = (weekday + 5) % 7 + (week.contains("다음") ? 7 : 0)
            }
            if let date = calendar.date(byAdding: .day, value: offset, to: base) { dateCandidates.append((m, date)) }
        }
        if dateCandidates.count == 1, let (m, date) = dateCandidates.first {
            result.scheduledDate = TaskDay(date, calendar: calendar); consume(m); result.preview.append(text(m))
        }
        var times: [(NSTextCheckingResult, Int, Int)] = []
        for m in matches(edge + "(오전|오후|저녁)\\s*(\\d{1,2})시(?:\\s*(\\d{1,2})분)?" + tail) where free(m.range) {
            guard let h = Int(text(m, 2)), (1...12).contains(h) else { continue }
            let minute = Int(text(m, 3)) ?? 0
            guard (0...59).contains(minute) else { continue }
            times.append((m, h % 12 + (text(m, 1) == "오전" ? 0 : 12), minute))
        }
        for m in matches(edge + "(\\d{1,2}):(\\d{2})" + tail) where free(m.range) {
            guard let h = Int(text(m, 1)), let minute = Int(text(m, 2)), (0...23).contains(h), (0...59).contains(minute) else { continue }
            times.append((m, h, minute))
        }
        // Protect even invalid/ambiguous clock expressions from day-period and duration passes.
        let clockRanges = matches(edge + "(?:(?:오전|오후|저녁)\\s*)?\\d{1,2}시(?:\\s*\\d{1,2}분)?" + tail).map(\.range)
        if times.count == 1, let (m, h, minute) = times.first {
            let day = result.scheduledDate.date(calendar: calendar)
            if let date = calendar.date(bySettingHour: h, minute: minute, second: 0, of: day, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
               calendar.isDate(date, inSameDayAs: day), calendar.component(.hour, from: date) == h,
               calendar.component(.minute, from: date) == minute {
                // Fall-back overlap is ambiguous too: don't silently select one occurrence.
                let second = calendar.date(bySettingHour: h, minute: minute, second: 0, of: day, matchingPolicy: .strict, repeatedTimePolicy: .last, direction: .forward)
                if second == date { result.scheduledAt = date; consume(m); result.preview.append(String(format: "%02d:%02d", h, minute)) }
            }
        }
        protected += clockRanges
        let periods = matches(edge + "(오전|오후|저녁)(?:에)?" + tail).filter { free($0.range) }
        if result.scheduledAt == nil, periods.count == 1, let m = periods.first {
            result.dayPeriod = text(m, 1) == "오전" ? .morning : (text(m, 1) == "오후" ? .afternoon : .evening)
            consume(m); result.preview.append(text(m, 1))
        }
        let durations = matches(edge + "(?:(\\d+)시간(?:\\s*(\\d+)분)?|(\\d+)분)" + tail).filter { free($0.range) }
        if durations.count == 1, let m = durations.first {
            let hoursText = text(m, 1), minuteText = text(m, 2).isEmpty ? text(m, 3) : text(m, 2)
            let h = hoursText.isEmpty ? 0 : Int(hoursText)
            let mm = minuteText.isEmpty ? 0 : Int(minuteText)
            if let hours = h, let minutes = mm, (0...24).contains(hours), (0...1440).contains(minutes), (1...1440).contains(hours * 60 + minutes) {
                result.estimatedMinutes = hours * 60 + minutes; consume(m); result.preview.append(text(m))
            }
        }
        for m in matches(edge + "(?:중요|급함|긴급)" + tail) where free(m.range) {
            result.priority = .important; consume(m)
        }
        if result.priority == .important { result.preview.append("중요") }
        let remaining = NSMutableString(string: input)
        for range in used.sorted(by: { $0.location > $1.location }) { remaining.replaceCharacters(in: range, with: " ") }
        let title = (remaining as String).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        result.title = used.isEmpty || title.isEmpty ? input.trimmingCharacters(in: .whitespacesAndNewlines) : title
        return result
    }
}
