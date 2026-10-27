import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct Sound: Identifiable, Hashable {
    let url: URL
    let isUser: Bool
    var name: String
    var id: String { url.path }

    init(url: URL, isUser: Bool, name: String? = nil) {
        self.url = url
        self.isUser = isUser
        self.name = name ?? url.deletingPathExtension().lastPathComponent
    }
}

/// The alarm sounds: the iPhone alarm tones macOS ships, the short macOS alerts, plus any audio file you add (copied into Tick's Sounds folder so it stays put).
@MainActor
final class SoundLibrary: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let folder: URL = {
        let root = ProcessInfo.processInfo.environment["TICK_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tick")
        return root.appendingPathComponent("Sounds")
    }()
    /// The iPhone's ringtone / alarm set (Radar, Opening, Apex…), in a private framework but plain .m4r files.
    static let tonesFolder = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones")
    /// Radar, like the iPhone's default alarm; Glass if this Mac doesn't have the tones.
    static let fallback: URL = {
        let radar = tonesFolder.appendingPathComponent("Radar.m4r")
        return FileManager.default.fileExists(atPath: radar.path) ? radar : URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    }()
    nonisolated static let extensions: Set<String> = ["m4r", "mp3", "wav", "wave", "aif", "aiff", "aifc", "m4a", "aac", "caf", "flac", "mp4"]

    @Published private(set) var user: [Sound] = []
    @Published private(set) var tones: [Sound] = []
    @Published private(set) var system: [Sound] = []
    @Published private(set) var selected: URL
    @Published var volume: Float { didSet { store.set(volume, forKey: "volume"); player?.volume = volume } }
    @Published private(set) var previewing = false

    private var player: AVAudioPlayer?
    private var ringing = false
    private var gapTimer: Timer?

    override init() {
        selected = store.string(forKey: "sound").map { URL(fileURLWithPath: $0) } ?? Self.fallback
        volume = store.object(forKey: "volume") as? Float ?? 0.8
        super.init()
        reload()
        if !FileManager.default.fileExists(atPath: selected.path) { selected = Self.fallback }
    }

    var current: Sound {
        (user + tones + system).first { $0.url == selected } ?? Sound(url: selected, isUser: selected.path.hasPrefix(Self.folder.path))
    }

    func reload() {
        let fm = FileManager.default
        func list(_ dir: URL, user: Bool) -> [Sound] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
                .map { Sound(url: $0, isUser: user) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        user = list(Self.folder, user: true)
        // The newer tones carry an "-EncoreInfinitum" suffix; one of them shares a name with an older tone.
        let raw = list(Self.tonesFolder, user: false)
        let plain = Set(raw.map(\.name))
        tones = raw.map { sound in
            guard let r = sound.name.range(of: "-EncoreInfinitum") else { return sound }
            let base = String(sound.name[..<r.lowerBound])
            return Sound(url: sound.url, isUser: false, name: plain.contains(base) ? "\(base) (New)" : base)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        system = list(URL(fileURLWithPath: "/System/Library/Sounds"), user: false)
    }

    nonisolated static func isAudio(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased()) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }

    func select(_ sound: Sound) {
        selected = sound.url
        store.set(sound.url.path, forKey: "sound")
    }

    /// Copies the file into the Sounds folder and makes it the alarm. Throws if it can't be played.
    @discardableResult
    func add(_ url: URL) throws -> Sound {
        _ = try AVAudioPlayer(contentsOf: url)
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var dest = Self.folder.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL.path != dest.standardizedFileURL.path {
            // Same name, different file: keep both.
            var n = 2
            while fm.fileExists(atPath: dest.path), !fm.contentsEqual(atPath: dest.path, andPath: url.path) {
                dest = Self.folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
                n += 1
            }
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: url, to: dest) }
        }
        reload()
        let sound = Sound(url: dest, isUser: true)
        select(sound)
        Log.write("sound added \(dest.lastPathComponent)")
        return sound
    }

    func remove(_ sound: Sound) {
        guard sound.isUser else { return }
        try? FileManager.default.trashItem(at: sound.url, resultingItemURL: nil)
        if selected == sound.url {
            selected = Self.fallback
            store.set(Self.fallback.path, forKey: "sound")
        }
        reload()
    }

    /// Asks for an audio file and adds it.
    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Alarm Sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try add(url) } catch { alert("Tick can't play “\(url.lastPathComponent)”.") }
    }

    func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = "Try an MP3, WAV, AIFF or M4A file."
        a.runModal()
    }

    // MARK: Playing

    func togglePreview() {
        if previewing {
            stopPlayer()
        } else {
            play(loop: false)
            previewing = player != nil
        }
    }

    /// Loops the alarm until stopAlarm(). Long files loop straight through; short ones repeat with a short gap.
    func startAlarm() {
        stopPlayer()
        ringing = true
        play(loop: true)
    }

    func stopAlarm() {
        ringing = false
        stopPlayer()
    }

    private func play(loop: Bool) {
        stopPlayer()
        guard let p = (try? AVAudioPlayer(contentsOf: selected)) ?? (try? AVAudioPlayer(contentsOf: Self.fallback)) else {
            NSSound.beep()
            return
        }
        p.volume = volume
        p.delegate = self
        if loop && p.duration >= 3 { p.numberOfLoops = -1 }
        p.play()
        player = p
        if loop { Log.write("alarm playing \(p.url?.lastPathComponent ?? "?") (\(String(format: "%.1f", p.duration)) s, \(p.numberOfLoops < 0 ? "looping" : "repeating"))") }
    }

    private func stopPlayer() {
        gapTimer?.invalidate()
        gapTimer = nil
        player?.stop()
        player = nil
        previewing = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard p === player else { return }
            if ringing {
                gapTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.ringing, let player = self.player else { return }
                        player.currentTime = 0
                        player.play()
                    }
                }
            } else {
                previewing = false
                player = nil
            }
        }
    }
}
