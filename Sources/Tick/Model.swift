import AppKit
import Foundation

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tick.log")
    private static let queue = DispatchQueue(label: "tick.log")
    private static var writes = 0

    /// Past 1 MB the log is cut down to its newest 256 KB, so it never keeps growing.
    private static func trim() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(256_000)
        if let newline = tail.firstIndex(of: 10) { tail = tail[(newline + 1)...] }
        try? tail.write(to: url, options: .atomic)
    }

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            writes += 1
            if writes % 200 == 1 { trim() }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Settings and the running timer live here; TICK_SUITE=<name> (and --snapshot) keep tests out of the real ones.
let store: UserDefaults = {
    let suite = ProcessInfo.processInfo.environment["TICK_SUITE"]
        ?? (CommandLine.arguments.contains("--snapshot") ? "com.byaydenrx.tick.snapshot" : nil)
    return suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
}()

// MARK: - Reading what was typed

struct Request: Equatable {
    var seconds: Double
    var label: String
    /// Set for "3pm" / "at 15:30" style input, so the preview can say "until 3:00 PM".
    var until: Date?
}

enum Parser {
    /// Reads "5", "25m", "1h30", "1h 30m", "90s", "2.5", "1:30", "1:02:00", "3pm", "3:30pm", "at 15:30",
    /// with anything after the time as the label ("5 tea", "25m focus").
    static func parse(_ text: String, now: Date = Date()) -> Request? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func label(after length: Int) -> String {
            String(original.dropFirst(length)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-·,:")))
        }

        // Clock times: "3pm", "3:30 pm", "at 7", "at 15:30".
        if let m = match(#"^(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, s) ?? match(#"^at\s*(\d{1,2})(?::(\d{2}))?\b"#, s) {
            var hour = Int(m.groups[0]!)!
            let minute = m.groups[1].flatMap { Int($0) } ?? 0
            let meridiem = m.groups.count > 2 ? m.groups[2] : nil
            guard minute < 60 else { return nil }
            if let meridiem {
                guard (1...12).contains(hour) else { return nil }
                if meridiem.hasPrefix("p"), hour != 12 { hour += 12 }
                if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
            }
            guard hour < 24 else { return nil }
            let calendar = Calendar.current
            guard var target = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            // "at 7" without am/pm means the next 7 o'clock, morning or evening.
            if meridiem == nil, hour < 12, target <= now, let evening = calendar.date(byAdding: .hour, value: 12, to: target), evening > now {
                target = evening
            }
            if target <= now { target = calendar.date(byAdding: .day, value: 1, to: target)! }
            return Request(seconds: target.timeIntervalSince(now).rounded(), label: label(after: m.length), until: target)
        }

        // "1:30" is minutes and seconds, "1:02:00" hours, minutes and seconds.
        if let m = match(#"^(\d+):(\d{1,2})(?::(\d{1,2}))?(?!\d)"#, s) {
            let parts = m.groups.compactMap { $0 }.map { Double($0)! }
            let seconds = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1]
            guard seconds > 0 else { return nil }
            return Request(seconds: seconds, label: label(after: m.length))
        }

        // Numbers with optional units. A bare first number is minutes; a bare number after hours is minutes,
        // after minutes it's seconds ("1h 30", "5m 30").
        var total = 0.0
        var consumed = 0
        var lastUnit: Double?
        var rest = Substring(s)
        while let m = match(#"^\s*(\d+(?:\.\d+)?|\.\d+)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)?(?![a-z])"#, String(rest)) {
            let value = Double(m.groups[0]!)!
            let unit: Double
            if let u = m.groups[1]?.first {
                unit = u == "h" ? 3600 : u == "m" ? 60 : 1
            } else if lastUnit == nil || lastUnit == 3600 {
                unit = 60
            } else if lastUnit == 60 {
                unit = 1
            } else {
                // A bare number right after seconds isn't part of the time: it starts the label.
                break
            }
            total += value * unit
            lastUnit = unit
            consumed += m.length
            rest = rest.dropFirst(m.length)
            if m.groups[1] == nil { break }
        }
        guard consumed > 0, total >= 1 else { return nil }
        return Request(seconds: total.rounded(), label: label(after: consumed))
    }

    private struct Match { var length: Int; var groups: [String?] }

    private static func match(_ pattern: String, _ s: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let r = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let groups = (1..<r.numberOfRanges).map { i -> String? in
            Range(r.range(at: i), in: s).map { String(s[$0]) }
        }
        return Match(length: r.range.length, groups: groups)
    }
}

enum Format {
    /// Countdown face: "4:59", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Short length: "25m", "1h 30m", "1m 30s", "45s".
    static func length(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 && h == 0 { parts.append("\(s)s") }
        return parts.isEmpty ? "0s" : parts.joined(separator: " ")
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - The timer

struct Recent: Codable, Equatable, Hashable {
    var seconds: Double
    var label: String
    var title: String { label.isEmpty ? Format.length(seconds) : "\(Format.length(seconds)) \(label)" }
}

enum Phase: Equatable {
    case idle
    case running(end: Date)
    case paused(remaining: Double)
    case ringing
}

@MainActor
final class TickModel: ObservableObject {
    static let presets: [Double] = [1, 5, 10, 15, 25, 45, 60].map { $0 * 60 }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var total: Double = 0
    @Published private(set) var label = ""
    @Published private(set) var recents: [Recent] = []
    /// Moves once a second while a timer runs, so the face redraws.
    @Published private(set) var now = Date()
    @Published var input = "" { didSet { if input != oldValue { invalid = false } } }
    @Published var invalid = false

    let sounds = SoundLibrary()
    /// The menu bar redraws on every change.
    var onChange: (() -> Void)?
    var onStarted: (() -> Void)?
    var onRing: (() -> Void)?
    var onRingStopped: (() -> Void)?
    var onEscape: (() -> Void)?
    /// The popover's content height, reported by the view whenever it changes.
    var onHeight: ((CGFloat) -> Void)?
    weak var field: NSTextField?

    private var ticker: Timer?
    private var endTimer: Timer?
    private var activity: NSObjectProtocol?
    private var silenceTimer: Timer?

    init() {
        recents = (store.data(forKey: "recents")).flatMap { try? JSONDecoder().decode([Recent].self, from: $0) } ?? []
        label = store.string(forKey: "label") ?? ""
        total = store.double(forKey: "total")
        let end = store.double(forKey: "end")
        let paused = store.double(forKey: "paused")
        if end > 0 {
            let date = Date(timeIntervalSince1970: end)
            // A timer that ran out while Tick was closed only rings if that was a moment ago.
            if date > Date() { phase = .running(end: date) } else if Date().timeIntervalSince(date) < 60 { phase = .running(end: Date()) }
        } else if paused > 0 {
            phase = .paused(remaining: paused)
        }
        if case .running = phase { schedule() }
    }

    var parsed: Request? { Parser.parse(input) }

    var remaining: Double {
        switch phase {
        case .idle, .ringing: 0
        case .running(let end): max(0, end.timeIntervalSince(now))
        case .paused(let r): r
        }
    }

    var progress: Double { total > 0 ? min(max(1 - remaining / total, 0), 1) : 0 }

    var endDate: Date? {
        if case .running(let end) = phase { return end }
        return nil
    }

    var isActive: Bool { phase != .idle }

    // MARK: Actions

    func submit() {
        guard let request = parsed else {
            invalid = !input.trimmingCharacters(in: .whitespaces).isEmpty
            NSSound.beep()
            return
        }
        start(request.seconds, label: request.label)
    }

    func start(_ seconds: Double, label: String = "") {
        stopRinging()
        total = seconds
        self.label = label
        now = Date()
        phase = .running(end: now.addingTimeInterval(seconds))
        input = ""
        remember(Recent(seconds: seconds, label: label))
        schedule()
        save()
        Log.write("start \(Format.length(seconds)) \(label)")
        onStarted?()
    }

    /// The last timer again (⌥-click the menu bar item, or ↑ in the field).
    var last: Recent? {
        store.data(forKey: "last").flatMap { try? JSONDecoder().decode(Recent.self, from: $0) }
    }

    func again() {
        guard let last else { return }
        start(last.seconds, label: last.label)
    }

    func togglePause() {
        switch phase {
        case .running:
            phase = .paused(remaining: remaining)
            unschedule()
        case .paused(let r):
            now = Date()
            phase = .running(end: now.addingTimeInterval(r))
            schedule()
        default: return
        }
        save()
    }

    func add(_ seconds: Double) {
        switch phase {
        case .running(let end):
            phase = .running(end: end.addingTimeInterval(seconds))
            total += seconds
            schedule()
        case .paused(let r):
            phase = .paused(remaining: r + seconds)
            total += seconds
        case .ringing, .idle:
            start(seconds, label: label)
            return
        }
        save()
    }

    func stop() {
        stopRinging()
        phase = .idle
        unschedule()
        save()
    }

    /// Silences the alarm; the timer is done.
    func dismiss() { stop() }

    // MARK: Ticking

    private func schedule() {
        unschedule()
        ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
        if let end = endDate {
            endTimer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            endTimer?.tolerance = 0
            RunLoop.main.add(endTimer!, forMode: .common)
        }
        // Keeps App Nap from stretching the timers while Tick sits in the background.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Timer running")
        }
        tick()
    }

    private func unschedule() {
        ticker?.invalidate()
        ticker = nil
        endTimer?.invalidate()
        endTimer = nil
        if let activity, phase != .ringing {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        onChange?()
    }

    private func tick() {
        guard case .running(let end) = phase else { return }
        let date = Date()
        if date >= end {
            now = date
            ring()
            return
        }
        // Redraw only when the shown second changes.
        if Int(end.timeIntervalSince(date).rounded(.up)) != Int(end.timeIntervalSince(now).rounded(.up)) {
            now = date
            onChange?()
        }
    }

    private func ring() {
        phase = .ringing
        unschedule()
        save()
        sounds.startAlarm()
        Log.write("ring \(label)")
        // Sound stops on its own after three minutes; the bell stays in the menu bar until dismissed.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sounds.stopAlarm() }
        }
        onRing?()
        onChange?()
    }

    private func stopRinging() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard phase == .ringing else { return }
        sounds.stopAlarm()
        Log.write("alarm stopped")
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        onRingStopped?()
    }

    // MARK: Saving

    private func remember(_ recent: Recent) {
        if let data = try? JSONEncoder().encode(recent) { store.set(data, forKey: "last") }
        // Plain presets are already one click away, so they don't fill up the recent row.
        if recent.label.isEmpty && Self.presets.contains(recent.seconds) { return }
        recents.removeAll { $0 == recent }
        recents.insert(recent, at: 0)
        recents = Array(recents.prefix(4))
        store.set(try? JSONEncoder().encode(recents), forKey: "recents")
    }

    func forget(_ recent: Recent) {
        recents.removeAll { $0 == recent }
        store.set(try? JSONEncoder().encode(recents), forKey: "recents")
    }

    private func save() {
        store.set(label, forKey: "label")
        store.set(total, forKey: "total")
        store.set(endDate?.timeIntervalSince1970 ?? 0, forKey: "end")
        if case .paused(let r) = phase { store.set(r, forKey: "paused") } else { store.set(0.0, forKey: "paused") }
        onChange?()
    }
}
