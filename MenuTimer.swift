// MenuTimer.swift — a small multi-timer that lives in the macOS menu bar.
// Build with ./build.sh (needs Xcode Command Line Tools, macOS 14+).
//
// PERF DESIGN (unchanged from 1.0.1):
//  - The store only publishes when something really changes (start/pause/finish/edit...).
//  - A tiny `Heartbeat` object drives ONLY the countdown texts and the menu bar label.
//  - One one-shot timer, aimed just past the next whole-second boundary (1 wake-up/second,
//    nothing scheduled when no timer is running).
//
// NEW IN 1.2:
//  - Drag the ":::" grip on the left of a timer to reorder the list. Order is saved.
//    Zero cost while idle: no timers, no polling, no extra publishes. The store only changes
//    when the dragged row crosses another row.
//
// NEW IN 1.1:
//  - New timers: click the 00 : 00 : 00 fields (hours / minutes / seconds) and type.
//  - -5m / -1m buttons next to +1m / +5m (never drops below 00:00:01).
//  - Click the big countdown to set the remaining time (e.g. 1:43:33 -> 43:33).
//    Click the name/status area (or the play button) to start/pause.
//  - The "add timer" fields and the editor fields live in small views with their own state, so typing
//    redraws only that one view, not the whole panel.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Settings you may want to tweak

private let alarmSoundName = "Glass"   // try: Frog, Hero, Ping, Submarine, Funk, Sosumi, Purr
private let alarmRepeatSeconds = 2.5   // gap between alarm repeats
private let alarmMaxRepeats = 12       // alarm silences itself after ~30 s
private let panelTitle = "timers"      // header text in the dropdown
private let panelWidth: CGFloat = 400  // dropdown width (the 4 +/- buttons + 3 controls need ~330 pt inside)
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

/// Created once, reused for every "Ends at ..." label.
private let endTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
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

/// "5" -> "05", "" -> "00". Longer strings are returned unchanged.
func padded(_ s: String) -> String {
    s.count >= 2 ? s : String(repeating: "0", count: 2 - s.count) + s
}

/// Hours / minutes / seconds text fields -> total seconds. Empty or invalid text counts as 0.
func hmsToSeconds(_ h: String, _ m: String, _ s: String) -> Int {
    (Int(h) ?? 0) * 3600 + (Int(m) ?? 0) * 60 + (Int(s) ?? 0)
}

/// Keeps ASCII digits only and the last two of them ("005" -> "05").
func sanitizeSegment(_ text: String) -> String {
    let digits = text.filter { $0 >= "0" && $0 <= "9" }
    return String(digits.suffix(2))
}

/// Called whenever a two-digit field changes. Works out what the user just typed (wherever the
/// caret was) and shifts those digits in from the right, like a microwave keypad:
///   "00" + 4 -> "04", then + 3 -> "43".   Deleting / replacing a selection is just sanitised.
func nextSegmentValue(old: String, new: String) -> String {
    if new.count <= old.count { return sanitizeSegment(new) }
    let o = Array(old), n = Array(new)
    var prefix = 0
    while prefix < o.count && prefix < n.count && o[prefix] == n[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < o.count - prefix && suffix < n.count - prefix
            && o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
    let inserted = String(n[prefix..<(n.count - suffix)])
    return sanitizeSegment(sanitizeSegment(old) + sanitizeSegment(inserted))
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

// MARK: - Heartbeat (the only thing that changes once per second)

/// Views that show a live countdown observe this; everything else observes the store only.
final class Heartbeat: ObservableObject {
    @Published private(set) var now = Date()
    func beat() { now = Date() }
}

// MARK: - Store

final class TimerStore: ObservableObject {
    @Published private(set) var items: [TimerItem] = []
    @Published private(set) var runtime: [UUID: Runtime] = [:]

    let heartbeat = Heartbeat()

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
        return endTimeFormatter.string(from: end)
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

    /// +1m / +5m / -1m / -5m buttons (pass a negative number to subtract).
    /// running -> changes the current run, paused -> changes what's left,
    /// idle -> changes the saved timer length itself, finished -> "+" snoozes (silence + run again), "-" does nothing.
    /// The result never drops below 1 second.
    func addTime(_ id: UUID, seconds: Int) {
        guard var r = runtime[id] else { return }
        let extra = TimeInterval(seconds)
        switch r.state {
        case .running:
            let left = max(1, remaining(of: id) + extra)
            r.endDate = Date().addingTimeInterval(left)
            runtime[id] = r
            updateTicker()   // end date moved -> re-aim the next wake-up
        case .paused:
            r.remaining = max(1, r.remaining + extra)
            runtime[id] = r
        case .idle:
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].duration = max(1, items[idx].duration + seconds)
            r.remaining = TimeInterval(items[idx].duration)
            runtime[id] = r
            save()
        case .finished:
            guard seconds > 0 else { return }
            r.remaining = extra
            r.endDate = Date().addingTimeInterval(extra)
            r.state = .running
            runtime[id] = r
            silenceIfNothingFinished()
            updateTicker()
        }
    }

    /// Sets the time left to an exact value (the click-the-countdown editor).
    /// running -> ends `seconds` from now, paused -> sets what's left,
    /// idle -> changes the saved timer length itself, finished -> ignored (the UI doesn't offer it).
    func setRemaining(_ id: UUID, seconds: Int) {
        guard seconds > 0, var r = runtime[id] else { return }
        let value = TimeInterval(seconds)
        switch r.state {
        case .running:
            r.endDate = Date().addingTimeInterval(value)
            runtime[id] = r
            updateTicker()
        case .paused:
            r.remaining = value
            runtime[id] = r
        case .idle:
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].duration = seconds
            r.remaining = value
            runtime[id] = r
            save()
        case .finished:
            return
        }
    }

    func add(name: String, seconds: Int) {
        let item = TimerItem(name: name.isEmpty ? "Timer" : name, duration: seconds)
        items.append(item)
        runtime[item.id] = Runtime(remaining: TimeInterval(seconds))
        save()
    }

    // MARK: Reordering (drag & drop)

    /// Which timer is being dragged right now. Deliberately NOT @Published: nothing needs to
    /// redraw when it changes.
    var draggingID: UUID?

    /// Live reorder: while the grip is dragged over another row, the dragged timer takes that row's place.
    func moveDragged(over targetID: UUID) {
        guard let dragged = draggingID, dragged != targetID,
              let from = items.firstIndex(where: { $0.id == dragged }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        save()   // a few tiny writes per drag, only when a row boundary is crossed
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        runtime[id] = nil
        save()
        updateTicker()
        silenceIfNothingFinished()
    }

    // MARK: Ticking
    // One-shot timer, re-armed after every tick. It wakes up just after the next whole-second
    // boundary of the soonest-ending timer (that's exactly when the displayed value changes),
    // and never later than the moment any running timer ends. Nothing is scheduled while no
    // timer is running, so the app idles at ~0% CPU.

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil

        let now = Date()
        let ends = runtime.values.compactMap { $0.state == .running ? $0.endDate : nil }
        guard let soonest = ends.min() else { return }

        let rem = soonest.timeIntervalSince(now)
        var delay: TimeInterval
        if rem <= 0 {
            delay = 0.01
        } else {
            delay = rem - rem.rounded(.down)      // time until the next whole-second boundary
            if delay == 0 { delay = 1 }            // exactly on a boundary -> wait for the next one
            delay += 0.01                          // land just past it so ceil() has flipped
        }
        // make sure any other timer ending sooner still fires its alarm on time
        for end in ends {
            let d = end.timeIntervalSince(now)
            if d > 0 && d + 0.01 < delay { delay = d + 0.01 }
        }

        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tick() }
        t.tolerance = 0.02   // may fire slightly late, never early
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = Date()
        var updated = runtime
        var justFinished = false
        for (id, r) in runtime where r.state == .running {
            if let end = r.endDate, end <= now {
                updated[id] = Runtime(state: .finished, remaining: 0, endDate: nil)
                justFinished = true
            }
        }
        if justFinished {
            runtime = updated      // single publish, only when something actually changed
            startAlarm()
        }
        heartbeat.beat()           // refresh countdown texts + menu bar label only
        updateTicker()
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
        t.tolerance = 0.25
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
    @ObservedObject var heartbeat: Heartbeat   // re-render once per second for the countdown text

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

/// The big countdown. This is the ONLY part of a row that redraws every second.
struct CountdownText: View {
    let store: TimerStore                       // plain reference: not observed on purpose
    @ObservedObject var heartbeat: Heartbeat    // observed: triggers the per-second redraw
    let id: UUID
    let color: Color

    var body: some View {
        Text(store.state(of: id) == .finished ? "00:00" : formatTime(store.remaining(of: id)))
            .font(.system(size: 34, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Three clickable two-digit fields:  HH : MM : SS.
/// Click a field and type: digits shift in from the right ("00" -> "04" -> "43").
/// Tab moves to the next field, Return calls `onCommit`.
struct TimeEntry: View {
    @Binding var h: String
    @Binding var m: String
    @Binding var s: String
    var fontSize: CGFloat
    var autofocus = false
    var onCommit: () -> Void

    private enum Field: Hashable { case h, m, s }
    @FocusState private var focus: Field?

    var body: some View {
        HStack(spacing: 2) {
            segment($h, .h)
            colon
            segment($m, .m)
            colon
            segment($s, .s)
        }
        .onChange(of: focus) { old, _ in
            // leaving a field: "4" -> "04"
            if let old = old {
                switch old {
                case .h: h = padded(h)
                case .m: m = padded(m)
                case .s: s = padded(s)
                }
            }
        }
        .onAppear {
            if autofocus {
                DispatchQueue.main.async { focus = .h }
            }
        }
    }

    private var colon: some View {
        Text(":")
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func segment(_ text: Binding<String>, _ field: Field) -> some View {
        TextField("00", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: fontSize * 1.5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(focus == field ? 0.20 : 0.08))
            )
            .focused($focus, equals: field)
            .onChange(of: text.wrappedValue) { old, new in
                let next = nextSegmentValue(old: old, new: new)
                if next != new { text.wrappedValue = next }
            }
            .onSubmit(onCommit)
    }
}

/// Tiny observable box for the editor / add-row fields. Used instead of @State: with the
/// newest SDKs @State is a macro whose plugin only ships with the full Xcode app, so it
/// fails to compile with Command Line Tools alone. @StateObject has no such requirement.
final class EntryModel: ObservableObject {
    @Published var editing = false
    @Published var name = ""
    @Published var h = "00"
    @Published var m = "00"
    @Published var s = "00"
}

/// The ":::" drag handle (2 columns x 3 rows of dots). Static, never redraws on its own.
struct GripHandle: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3.5, height: 3.5)
                    Circle().frame(width: 3.5, height: 3.5)
                }
            }
        }
        .foregroundStyle(.tertiary)
        .frame(width: 18, height: 38)          // comfortable grab area
        .contentShape(Rectangle())
        .help("Drag to reorder")
    }
}

/// Small look-alike shown under the cursor while dragging (cheap: just two texts).
struct DragPreview: View {
    let name: String
    let time: String

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(time)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }
}

/// Drop target for reordering. `target == nil` is the catch-all on the whole panel, so a drop that
/// lands between rows is still accepted (no snap-back animation).
struct ReorderDelegate: DropDelegate {
    let target: UUID?
    let store: TimerStore

    func validateDrop(info: DropInfo) -> Bool { store.draggingID != nil }

    func dropEntered(info: DropInfo) {
        if let target = target { store.moveDragged(over: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingID = nil
        return true
    }
}

struct TimerRow: View {
    @ObservedObject var store: TimerStore
    let heartbeat: Heartbeat                    // passed down, NOT observed here
    let item: TimerItem

    // editor state lives here, so typing redraws only this row
    @StateObject private var ed = EntryModel()

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

    private var editTotal: Int { hmsToSeconds(ed.h, ed.m, ed.s) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top: name + status on the left (click = start/pause), time on the right (click = edit).
            HStack(alignment: .top, spacing: 6) {
                GripHandle()
                    .onDrag({
                        store.draggingID = item.id
                        return NSItemProvider(object: item.id.uuidString as NSString)
                    }, preview: {
                        DragPreview(name: item.name, time: formatTime(store.remaining(of: item.id)))
                    })

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.toggle(item.id) }

                timeArea
            }

            controls
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .onChange(of: state) { _, new in
            if new == .finished { ed.editing = false }   // timer ran out while editing
        }
        .onDrop(of: [.text], delegate: ReorderDelegate(target: item.id, store: store))
    }

    // MARK: Time area (countdown, or the editor)

    @ViewBuilder
    private var timeArea: some View {
        if ed.editing && state != .finished {
            HStack(spacing: 6) {
                TimeEntry(h: $ed.h, m: $ed.m, s: $ed.s, fontSize: 24, autofocus: true, onCommit: commitEdit)
                smallButton("checkmark", enabled: editTotal > 0) { commitEdit() }
                smallButton("xmark", enabled: true) { ed.editing = false }
            }
            .onExitCommand { ed.editing = false }
        } else {
            CountdownText(store: store, heartbeat: heartbeat, id: item.id, color: timeColor)
                .contentShape(Rectangle())
                .onTapGesture {
                    if state == .finished {
                        store.toggle(item.id)   // same as before: silence + reset
                    } else {
                        beginEdit()
                    }
                }
        }
    }

    private func beginEdit() {
        let total = Int(store.remaining(of: item.id).rounded(.up))
        ed.h = padded(String(min(total / 3600, 99)))
        ed.m = padded(String((total % 3600) / 60))
        ed.s = padded(String(total % 60))
        ed.editing = true
    }

    private func commitEdit() {
        let total = hmsToSeconds(ed.h, ed.m, ed.s)
        guard total > 0 else { return }
        store.setRemaining(item.id, seconds: total)
        ed.editing = false
    }

    // MARK: Buttons

    private var controls: some View {
        HStack(spacing: 6) {
            pill("\u{2212}5m", enabled: state != .finished) { store.addTime(item.id, seconds: -300) }
            pill("\u{2212}1m", enabled: state != .finished) { store.addTime(item.id, seconds: -60) }
            pill("+1m") { store.addTime(item.id, seconds: 60) }
            pill("+5m") { store.addTime(item.id, seconds: 300) }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                // Reset: stops the timer and puts it back to its full length (e.g. 59:58 -> 1:00:00)
                circleButton("arrow.counterclockwise", tint: nil) { store.reset(item.id) }
                    .opacity(state == .idle ? 0.35 : 1)
                    .disabled(state == .idle)
                circleButton(primaryIcon, tint: nil) { store.toggle(item.id) }
                circleButton("xmark", tint: closePink) { store.remove(item.id) }
            }
        }
    }

    private func pill(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func circleButton(_ systemName: String, tint: Color?, action: @escaping () -> Void) -> some View {
        let base = tint ?? Color.primary
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(base)
                .frame(width: 34, height: 34)
                .background(Circle().fill(base.opacity(tint == nil ? 0.10 : 0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// "New timer" row: name + HH:MM:SS fields + add button. Owns its own EntryModel.
struct AddTimerRow: View {
    let store: TimerStore                       // plain reference: not observed on purpose

    @StateObject private var ed = EntryModel()

    private var total: Int { hmsToSeconds(ed.h, ed.m, ed.s) }

    var body: some View {
        HStack(spacing: 8) {
            TextField("New timer name", text: $ed.name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .onSubmit(addTimer)
            TimeEntry(h: $ed.h, m: $ed.m, s: $ed.s, fontSize: 18, onCommit: addTimer)
            Button(action: addTimer) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(total == 0)
            .opacity(total == 0 ? 0.35 : 1)
        }
    }

    private func addTimer() {
        guard total > 0 else { return }
        store.add(name: ed.name.trimmingCharacters(in: .whitespaces), seconds: total)
        ed.name = ""
        ed.h = "00"
        ed.m = "00"
        ed.s = "00"
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
                TimerRow(store: store, heartbeat: store.heartbeat, item: item)
            }

            AddTimerRow(store: store)

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
        .frame(width: panelWidth)
        .onDrop(of: [.text], delegate: ReorderDelegate(target: nil, store: store))
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
            MenuLabel(store: store, heartbeat: store.heartbeat)
        }
        .menuBarExtraStyle(.window)
    }
}
