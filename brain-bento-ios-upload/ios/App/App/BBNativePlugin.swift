import UIKit
import Capacitor
import AVFoundation
import GameKit
import MusicKit
import UserNotifications

/// Brain Bento's bridge from the web games to iOS:
/// haptics, the share sheet, Game Center leaderboards, a daily reminder,
/// Apple Music (MusicKit search, preview clips, full songs for subscribers)
/// and a backup copy of the player's scores.
/// The web side calls these with Capacitor.nativePromise("BBNative", method, options).
@objc(BBNativePlugin)
public class BBNativePlugin: CAPPlugin, CAPBridgedPlugin, GKGameCenterControllerDelegate {
    public let identifier = "BBNativePlugin"
    public let jsName = "BBNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "info", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "haptic", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "share", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "backupSave", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "backupLoad", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "gcAuth", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "gcSubmit", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "gcShow", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "notifPermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "notifSchedule", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "notifCancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "musicStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "musicAuthorize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "musicFind", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clipLoad", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clipPlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clipStop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "fullPlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "fullStop", returnType: CAPPluginReturnPromise)
    ]

    // MARK: - Basics

    @objc func info(_ call: CAPPluginCall) {
        let dict = Bundle.main.infoDictionary ?? [:]
        call.resolve([
            "version": dict["CFBundleShortVersionString"] as? String ?? "",
            "build": dict["CFBundleVersion"] as? String ?? ""
        ])
    }

    @objc func haptic(_ call: CAPPluginCall) {
        let style = call.getString("style") ?? "light"
        DispatchQueue.main.async {
            switch style {
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "error":
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "warning":
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "medium":
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy":
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            default:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            call.resolve()
        }
    }

    @objc func share(_ call: CAPPluginCall) {
        let text = call.getString("text") ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let host = self?.bridge?.viewController else {
                call.reject("No screen to share from")
                return
            }
            let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = host.view
                pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.maxY - 90, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                call.resolve(["completed": completed])
            }
            host.present(sheet, animated: true)
        }
    }

    @objc func openUrl(_ call: CAPPluginCall) {
        guard let raw = call.getString("url"), let url = URL(string: raw) else {
            call.reject("Bad link")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                call.resolve(["ok": ok])
            }
        }
    }

    @objc func openSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            call.resolve()
        }
    }

    // MARK: - Score backup (a copy of the web view's saved stats, in Application Support)

    private func backupURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("brainbento-backup.json")
    }

    @objc func backupSave(_ call: CAPPluginCall) {
        let text = call.getString("data") ?? ""
        do {
            let url = try backupURL()
            try Data(text.utf8).write(to: url, options: .atomic)
            call.resolve(["ok": true])
        } catch {
            call.reject("Couldn't save the backup")
        }
    }

    @objc func backupLoad(_ call: CAPPluginCall) {
        do {
            let url = try backupURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                call.resolve(["data": ""])
                return
            }
            let bytes = try Data(contentsOf: url)
            call.resolve(["data": String(decoding: bytes, as: UTF8.self)])
        } catch {
            call.resolve(["data": ""])
        }
    }

    // MARK: - Game Center

    private var gcWaiting: [CAPPluginCall] = []
    private var gcStarted = false

    @objc func gcAuth(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let player = GKLocalPlayer.local
            if player.isAuthenticated {
                call.resolve(["authenticated": true, "alias": player.alias])
                return
            }
            if self.gcStarted {
                // GameKit only offers its sign-in sheet once per launch; after that, sign-in happens in the Settings app.
                call.resolve(["authenticated": false, "alias": ""])
                return
            }
            self.gcStarted = true
            self.gcWaiting.append(call)
            player.authenticateHandler = { [weak self] signInScreen, error in
                guard let self = self else { return }
                if let screen = signInScreen {
                    self.bridge?.viewController?.present(screen, animated: true)
                    return
                }
                let ok = GKLocalPlayer.local.isAuthenticated
                let result: [String: Any] = [
                    "authenticated": ok,
                    "alias": ok ? GKLocalPlayer.local.alias : "",
                    "error": error?.localizedDescription ?? ""
                ]
                let waiting = self.gcWaiting
                self.gcWaiting = []
                waiting.forEach { $0.resolve(result) }
            }
        }
    }

    @objc func gcSubmit(_ call: CAPPluginCall) {
        guard let board = call.getString("id") else {
            call.reject("Missing leaderboard id")
            return
        }
        let score = call.getInt("score") ?? 0
        guard GKLocalPlayer.local.isAuthenticated else {
            call.reject("Not signed in to Game Center")
            return
        }
        GKLeaderboard.submitScore(score, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [board]) { error in
            if let error = error {
                call.reject(error.localizedDescription)
            } else {
                call.resolve(["ok": true])
            }
        }
    }

    @objc func gcShow(_ call: CAPPluginCall) {
        let board = call.getString("id")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let host = self.bridge?.viewController else {
                call.reject("No screen")
                return
            }
            let screen: GKGameCenterViewController
            if let board = board {
                screen = GKGameCenterViewController(leaderboardID: board, playerScope: .global, timeScope: .allTime)
            } else {
                screen = GKGameCenterViewController(state: .leaderboards)
            }
            screen.gameCenterDelegate = self
            host.present(screen, animated: true)
            call.resolve()
        }
    }

    public func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true)
    }

    // MARK: - Daily reminder (a local notification, scheduled on the phone itself)

    private let reminderID = "bb.daily"

    @objc func notifPermission(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            call.resolve(["granted": granted])
        }
    }

    @objc func notifSchedule(_ call: CAPPluginCall) {
        let content = UNMutableNotificationContent()
        content.title = call.getString("title") ?? "Brain Bento"
        content.body = call.getString("body") ?? "Today's games are waiting."
        content.sound = .default
        var when = DateComponents()
        when.hour = min(max(call.getInt("hour") ?? 18, 0), 23)
        when.minute = min(max(call.getInt("minute") ?? 0, 0), 59)
        let request = UNNotificationRequest(identifier: reminderID, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        center.add(request) { error in
            if let error = error {
                call.reject(error.localizedDescription)
            } else {
                call.resolve(["ok": true])
            }
        }
    }

    @objc func notifCancel(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderID])
        call.resolve()
    }

    // MARK: - Apple Music (MusicKit)

    private var songs: [String: Song] = [:]

    private func statusName(_ status: MusicAuthorization.Status) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "notDetermined"
        }
    }

    @objc func musicStatus(_ call: CAPPluginCall) {
        Task {
            let status = MusicAuthorization.currentStatus
            var canPlay = false
            if status == .authorized {
                do {
                    let subscription = try await MusicSubscription.current
                    canPlay = subscription.canPlayCatalogContent
                } catch {
                    canPlay = false
                }
            }
            call.resolve(["auth": self.statusName(status), "canPlay": canPlay])
        }
    }

    @objc func musicAuthorize(_ call: CAPPluginCall) {
        Task {
            let status = await MusicAuthorization.request()
            call.resolve(["auth": self.statusName(status)])
        }
    }

    /// Searches the Apple Music catalog. Returns up to `limit` songs with their preview clip,
    /// cover art, Apple Music link and explicit flag. The web side picks the right (clean) recording.
    @objc func musicFind(_ call: CAPPluginCall) {
        let term = call.getString("term") ?? ""
        let limit = min(max(call.getInt("limit") ?? 10, 1), 25)
        Task {
            do {
                var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
                request.limit = limit
                let response = try await request.response()
                var found: [[String: Any]] = []
                for song in response.songs {
                    var item: [String: Any] = [
                        "id": song.id.rawValue,
                        "title": song.title,
                        "artist": song.artistName,
                        "explicit": song.contentRating == .explicit
                    ]
                    if let preview = song.previewAssets?.first?.url {
                        item["preview"] = preview.absoluteString
                    }
                    if let art = song.artwork?.url(width: 400, height: 400) {
                        item["artwork"] = art.absoluteString
                    }
                    if let link = song.url {
                        item["url"] = link.absoluteString
                    }
                    self.songs[song.id.rawValue] = song
                    found.append(item)
                }
                call.resolve(["songs": found])
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    // Preview clips play through AVPlayer. A boundary observer stops them on the exact
    // media time, so a 0.1 second clip is 0.1 seconds of the song even if the network stalls.
    private var player: AVPlayer?
    private var loadedURL = ""
    private var readyObserver: NSKeyValueObservation?
    private var boundary: Any?
    private var playing: CAPPluginCall?
    private var safety: DispatchWorkItem?

    @objc func clipLoad(_ call: CAPPluginCall) {
        guard let raw = call.getString("url"), let url = URL(string: raw) else {
            call.reject("Bad clip link")
            return
        }
        let start = call.getDouble("start") ?? 0
        DispatchQueue.main.async {
            self.finishClip()
            if self.loadedURL == raw, let item = self.player?.currentItem, item.status == .readyToPlay {
                call.resolve(["ok": true])
                return
            }
            let item = AVPlayerItem(url: url)
            let player = self.player ?? AVPlayer()
            player.automaticallyWaitsToMinimizeStalling = false
            player.replaceCurrentItem(with: item)
            self.player = player
            self.loadedURL = raw
            var settled = false
            let settle: (Bool, String) -> Void = { ok, message in
                if settled { return }
                settled = true
                self.readyObserver?.invalidate()
                self.readyObserver = nil
                if !ok {
                    call.reject(message)
                    return
                }
                // park the playhead where the first clip starts, so it plays the moment someone taps
                item.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    call.resolve(["ok": true, "duration": item.duration.seconds.isFinite ? item.duration.seconds : 0])
                }
            }
            self.readyObserver = item.observe(\.status, options: [.initial, .new]) { observed, _ in
                DispatchQueue.main.async {
                    if observed.status == .readyToPlay {
                        settle(true, "")
                    } else if observed.status == .failed {
                        settle(false, observed.error?.localizedDescription ?? "Couldn't load the clip")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                settle(false, "The clip took too long to load")
            }
        }
    }

    @objc func clipPlay(_ call: CAPPluginCall) {
        let start = max(0, call.getDouble("start") ?? 0)
        let length = max(0.05, call.getDouble("dur") ?? 1)
        DispatchQueue.main.async {
            guard let player = self.player, let item = player.currentItem else {
                call.reject("No clip loaded")
                return
            }
            self.finishClip()
            self.playing = call
            self.fade(item, start: start, length: length)
            let from = CMTime(seconds: start, preferredTimescale: 600)
            let to = CMTime(seconds: start + length, preferredTimescale: 600)
            player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async {
                    guard self.playing === call else { return }
                    self.boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: to)], queue: .main) { [weak self] in
                        self?.finishClip()
                    }
                    player.play()
                    let backstop = DispatchWorkItem { [weak self] in self?.finishClip() }
                    self.safety = backstop
                    DispatchQueue.main.asyncAfter(deadline: .now() + length + 5, execute: backstop)
                }
            }
        }
    }

    @objc func clipStop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.finishClip()
            call.resolve()
        }
    }

    /// Short fades at both ends of a clip, so it doesn't click.
    private func fade(_ item: AVPlayerItem, start: Double, length: Double) {
        guard let track = item.tracks.compactMap({ $0.assetTrack }).first(where: { $0.mediaType == .audio }) else { return }
        let ramp = min(0.03, length / 4)
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                             timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                    duration: CMTime(seconds: ramp, preferredTimescale: 600)))
        params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                             timeRange: CMTimeRange(start: CMTime(seconds: start + length - ramp, preferredTimescale: 600),
                                                    duration: CMTime(seconds: ramp, preferredTimescale: 600)))
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    private func finishClip() {
        player?.pause()
        if let token = boundary {
            player?.removeTimeObserver(token)
            boundary = nil
        }
        safety?.cancel()
        safety = nil
        if let call = playing {
            playing = nil
            call.resolve(["ok": true])
        }
    }

    /// Plays the whole song (Apple Music subscribers only).
    @objc func fullPlay(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Missing song id")
            return
        }
        DispatchQueue.main.async { self.finishClip() }
        Task {
            do {
                var song = self.songs[id]
                if song == nil {
                    let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
                    song = try await request.response().items.first
                }
                guard let found = song else {
                    call.reject("Song not found")
                    return
                }
                try await self.startFull(found)
                call.resolve(["ok": true])
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func startFull(_ song: Song) async throws {
        let musicPlayer = ApplicationMusicPlayer.shared
        musicPlayer.queue = [song]
        try await musicPlayer.play()
    }

    @objc func fullStop(_ call: CAPPluginCall) {
        Task { @MainActor in
            ApplicationMusicPlayer.shared.pause()
            call.resolve()
        }
    }
}
