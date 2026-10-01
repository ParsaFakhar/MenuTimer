// MenuTimer.swift — a small multi-timer that lives in the macOS menu bar.
// Build with ./build.sh (needs Xcode Command Line Tools, macOS 14+).

import SwiftUI
import AppKit

// MARK: - Settings you may want to tweak

private let alarmSoundName = "Glass"   // try: Frog, Hero, Ping, Submarine, Funk, Sosumi, Purr
private let alarmRepeatSeconds = 2.5   // gap between alarm repeats
private let alarmMaxRepeats = 12       // alarm silences itself after ~30 s
private let panelTitle = "timers"      // header text in the dropdown
private let menuBarSymbol = "timer"    // fallback icon if MenuBarIcon.png is missing (any SF Symbol name)

private let runningGreen = Color(red: 0.36, green: 0.68, blue: 0.36)
private let closePink = Color(red: 0.95, green: 0.40, blue: 0.55)

// MARK: - Helpers

/// Our own menu bar glyph (MenuBarIcon.png inside the app). Template = macOS tints it for light/dark.
private let menuBarImage: NSImage? = {
    guard let img = NSImage(named: NSImage.Name("MenuBarIcon")) else { return nil }
    img.isTemplate = true
    img.size = NSSize(width: 18, height: 18)
    return img
}()

func formatTime(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, sec)
        : String(format: "%02d:%02d", m, sec)
}

/// Accepts "25" (minutes), "1:30" (min:sec) or "1:00:00" (h:min:sec).
func parseDuration(_ text: String) -> Int? {
    let parts = text
        .trimmingCharacters(in: .whitespaces)
        .split(separator: ":")
        .map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
    let nums = parts.compactMap { $0 }
    let total: Int
    switch nums.count {
    case 1: total = nums[0] * 60
    case 2: total = nums[0] * 60 + nums[1]
    case 3: total = nums[0] * 3600 + nums[1] * 60 + nums[2]
    default: return nil
    }
    return total > 0 ? total : nil
}

// MARK: - Model

struct TimerItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var duration: Int   // seconds
}

enum RunState { case idle, running, paused, finished }

struct Runtime {
    var state: RunState = .idle
    var remaining: TimeInterval
    var endDate: Date?
}

// MARK: - Store

final class TimerStore: ObservableObject {
    @Published private(set) var items: [TimerItem] = []
    @Published private(set) var runtime: [UUID: Runtime] = [:]
    // "add timer" form fields live here (instead of @State) so no SwiftUI macro plugin is needed
    @Published var draftName = ""
    @Published var draftLength = ""

    private var ticker: Timer?
    private var alarmTimer: Timer?
    private var alarmRepeats = 0
    private let storageKey = "timers.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([TimerItem].self, from: data) {
            items = saved
        } else {
            items = [
                TimerItem(name: "Focus", duration: 25 * 60),
                TimerItem(name: "Break", duration: 5 * 60),
                TimerItem(name: "Tea", duration: 3 * 60)
            ]
        }
        for item in items {
            runtime[item.id] = Runtime(remaining: TimeInterval(item.duration))
        }
    }

    // MARK: Queries

    func state(of id: UUID) -> RunState { runtime[id]?.state ?? .idle }

    func remaining(of id: UUID) -> TimeInterval {
        guard let r = runtime[id] else { return 0 }
        if r.state == .running, let end = r.endDate {
            return max(0, end.timeIntervalSinceNow)
        }
        return r.remaining
    }

    /// "11:47 AM" while a timer is running, otherwise nil.
    func endsAt(_ id: UUID) -> String? {
        guard let r = runtime[id], r.state == .running, let end = r.endDate else { return nil }
        return end.formatted(date: .omitted, time: .shortened)
    }

    var anyFinished: Bool { runtime.values.contains { $0.state == .finished } }
    var anyRunning: Bool { runtime.values.contains { $0.state == .running } }

    /// Text shown next to the icon in the menu bar.
    var menuBarText: String? {
        if anyFinished { return "Done" }
        let soonest = items
            .filter { state(of: $0.id) == .running }
            .map { remaining(of: $0.id) }
            .min()
        return soonest.map(formatTime)
    }

    // MARK: Actions

    /// idle/paused -> start, running -> pause, finished -> silence + reset.
    func toggle(_ id: UUID) {
        switch state(of: id) {
        case .idle, .paused: start(id)
        case .running: pause(id)
        case .finished: reset(id)
        }
    }

    func start(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              var r = runtime[id] else { return }
        if r.state == .idle || r.state == .finished || r.remaining <= 0 {
            r.remaining = TimeInterval(item.duration)
        }
        r.endDate = Date().addingTimeInterval(r.remaining)
        r.state = .running
        runtime[id] = r
        updateTicker()
    }

    func pause(_ id: UUID) {
        guard var r = runtime[id], r.state == .running else { return }
        r.remaining = remaining(of: id)
        r.endDate = nil
        r.state = .paused
        runtime[id] = r
        updateTicker()
    }

    func reset(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        runtime[id] = Runtime(remaining: TimeInterval(item.duration))
        updateTicker()
        silenceIfNothingFinished()
    }

    /// +1m / +5m buttons.
    /// running -> extends the current run, paused -> extends what's left,
    /// idle -> makes the saved timer itself longer, finished -> snooze (silence + run again).
    func addTime(_ id: UUID, seconds: Int) {
        guard var r = runtime[id] else { return }
        let extra = TimeInterval(seconds)
        switch r.state {
        case .running:
            r.endDate = (r.endDate ?? Date()).addingTimeInterval(extra)
            runtime[id] = r
        case .paused:
            r.remaining += extra
            runtime[id] = r
        case .idle:
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].duration += seconds
            r.remaining = TimeInterval(items[idx].duration)
            runtime[id] = r
            save()
        case .finished:
            r.remaining = extra
            r.endDate = Date().addingTimeInterval(extra)
            r.state = .running
            runtime[id] = r
            silenceIfNothingFinished()
            updateTicker()
        }
    }

    func add(name: String, seconds: Int) {
        let item = TimerItem(name: name.isEmpty ? "Timer" : name, duration: seconds)
        items.append(item)
        runtime[item.id] = Runtime(remaining: TimeInterval(seconds))
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        runtime[id] = nil
        save()
        updateTicker()
        silenceIfNothingFinished()
    }

    // MARK: Ticking (only runs while a timer is running, so it idles at ~0% CPU)

    private func updateTicker() {
        if anyRunning {
            guard ticker == nil else { return }
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        let now = Date()
        var justFinished = false
        for (id, r) in runtime where r.state == .running {
            if let end = r.endDate, end <= now {
                runtime[id] = Runtime(state: .finished, remaining: 0, endDate: nil)
                justFinished = true
            }
        }
        if justFinished { startAlarm() }
        updateTicker()
        objectWillChange.send()   // refresh the countdown display
    }

    // MARK: Alarm

    private func playSound() {
        NSSound(named: NSSound.Name(alarmSoundName))?.play()
    }

    private func startAlarm() {
        guard alarmTimer == nil else { return }
        alarmRepeats = 0
        playSound()
        let t = Timer(timeInterval: alarmRepeatSeconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.alarmRepeats += 1
            if self.alarmRepeats >= alarmMaxRepeats || !self.anyFinished {
                self.stopAlarm()
            } else {
                self.playSound()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        alarmTimer = t
    }

    private func stopAlarm() {
        alarmTimer?.invalidate()
        alarmTimer = nil
    }

    private func silenceIfNothingFinished() {
        if !anyFinished { stopAlarm() }
    }

    // MARK: Persistence (timer definitions only)

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Views

struct MenuLabel: View {
    @ObservedObject var store: TimerStore

    var body: some View {
        HStack(spacing: 4) {
            if store.anyFinished {
                Image(systemName: "bell.fill")
            } else if let img = menuBarImage {
                Image(nsImage: img)
            } else {
                Image(systemName: menuBarSymbol)
            }
            if let text = store.menuBarText {
                Text(text).monospacedDigit()
            }
        }
    }
}

struct TimerRow: View {
    @ObservedObject var store: TimerStore
    let item: TimerItem

    private var state: RunState { store.state(of: item.id) }

    private var subtitle: String {
        switch state {
        case .idle: return "Ready"
        case .running: return "Ends at \(store.endsAt(item.id) ?? "")"
        case .paused: return "Paused"
        case .finished: return "Time's up"
        }
    }

    private var timeColor: Color {
        switch state {
        case .running: return runningGreen
        case .paused: return Color.secondary
        case .finished: return Color.red
        case .idle: return Color.primary
        }
    }

    private var primaryIcon: String {
        switch state {
        case .running: return "pause.fill"
        case .finished: return "stop.fill"
        case .idle, .paused: return "play.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top: name + status on the left, big time on the right. Click to start/pause.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(state == .finished ? "00:00" : formatTime(store.remaining(of: item.id)))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundStyle(timeColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.toggle(item.id) }

            // Bottom: +1m / +5m on the left, controls on the right.
            HStack(spacing: 8) {
                pill("+ 1m") { store.addTime(item.id, seconds: 60) }
                pill("+ 5m") { store.addTime(item.id, seconds: 300) }
                Spacer(minLength: 0)
                // Reset: stops the timer and puts it back to its full length (e.g. 59:58 -> 1:00:00)
                circleButton("arrow.counterclockwise", tint: nil) { store.reset(item.id) }
                    .opacity(state == .idle ? 0.35 : 1)
                    .disabled(state == .idle)
                circleButton(primaryIcon, tint: nil) { store.toggle(item.id) }
                circleButton("xmark", tint: closePink) { store.remove(item.id) }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func circleButton(_ systemName: String, tint: Color?, action: @escaping () -> Void) -> some View {
        let base = tint ?? Color.primary
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(base)
                .frame(width: 36, height: 36)
                .background(Circle().fill(base.opacity(tint == nil ? 0.10 : 0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    @ObservedObject var store: TimerStore

    private var countLabel: String {
        let n = store.items.count
        return "\(n) TIMER\(n == 1 ? "" : "S")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text(panelTitle)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                Spacer()
                Text(countLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if store.items.isEmpty {
                Text("No timers yet. Add one below.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            ForEach(store.items) { item in
                TimerRow(store: store, item: item)
            }

            // Add a new timer
            HStack(spacing: 8) {
                TextField("New timer name", text: $store.draftName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                TextField("mm or mm:ss", text: $store.draftLength)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .frame(width: 104)
                    .onSubmit(addTimer)
                Button(action: addTimer) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(parseDuration(store.draftLength) == nil)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func addTimer() {
        guard let seconds = parseDuration(store.draftLength) else { return }
        store.add(name: store.draftName.trimmingCharacters(in: .whitespaces), seconds: seconds)
        store.draftName = ""
        store.draftLength = ""
    }
}

// MARK: - App

@main
struct MenuTimerApp: App {
    @StateObject private var store = TimerStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
