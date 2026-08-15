import Foundation
import RoostCore

/// Keeps the count up to date.
///
/// Two clocks, because the two halves come from different places and cost
/// different amounts: the transcripts are on disk and are caught up often, the
/// limits are a request over the network and are asked for rarely.
@MainActor
@Observable
final class UsageTracker {
    private(set) var snapshot = UsageSnapshot()

    @ObservationIgnored private let scanner = UsageScanner()
    @ObservationIgnored private var work: Task<Void, Never>?

    /// How often the transcripts are caught up. A pass over an idle machine is
    /// a few hundred file dates and nothing else; the reading itself only ever
    /// touches what was appended.
    private static let scanEvery: Duration = .seconds(15)

    /// How often the limits are asked for.
    ///
    /// Two minutes rather than one: the endpoint is rate limited, and Roost is
    /// not its only caller — Claude Code asks at the same address with the same
    /// token, once per pane. Asked every minute on a machine running half a
    /// dozen agents, the answer was `429` more often than not. The percentages
    /// move over hours; nothing is lost by asking half as often.
    private static let askEvery: TimeInterval = 120

    /// How long to wait after being turned away, and the ceiling on it. The
    /// interval doubles per refusal and returns to [askEvery] on the first
    /// answer — the polite reading of "later" when nobody says how much later.
    private static let askAtMost: TimeInterval = 15 * 60

    /// How often what has been counted is written down. Rarely on purpose: the
    /// file holds a row per reply of the last week, and the numbers it saves
    /// can all be read again — a save missed to a crash costs one slow launch.
    private static let saveEvery: TimeInterval = 120

    func start() {
        guard work == nil else { return }

        work = Task { [weak self] in
            var lastAsked = Date.distantPast
            var askAgainIn = Self.askEvery

            // Far back, so the first pass is written down the moment it
            // finishes: that one costs twelve seconds and a gigabyte, and it is
            // the whole reason the file exists.
            var lastSaved = Date.distantPast

            // What the last run counted, so this one only reads the tails.
            await self?.restore()

            while !Task.isCancelled {
                // The limits are asked for on the slower clock, and first: the
                // window's boundaries come from the answer, so a fresh reset
                // time makes the count that follows land in the right window.
                if Date().timeIntervalSince(lastAsked) >= askAgainIn {
                    let turnedAway = await self?.askForLimits() ?? false
                    lastAsked = Date()

                    askAgainIn = turnedAway
                        ? min(askAgainIn * 2, Self.askAtMost)
                        : Self.askEvery
                }

                await self?.catchUp()

                if Date().timeIntervalSince(lastSaved) >= Self.saveEvery {
                    await self?.write()
                    lastSaved = Date()
                }

                try? await Task.sleep(for: Self.scanEvery)
            }
        }
    }

    func stop() {
        work?.cancel()
        work = nil
    }

    private func restore() async {
        // The saved ledger is worth showing before the first pass finishes: it
        // is what was true when the app was last closed, which is a better
        // answer than "counting…" for the second or two that follow.
        if let restored = await scanner.restore() { snapshot = restored }
    }

    private func write() async {
        await scanner.save()
    }

    /// Catches the count up now, without waiting for the next tick — what a
    /// hook calls when an agent has just finished writing.
    func poke() {
        Task { await catchUp() }
    }

    private func catchUp() async {
        let updated = await scanner.catchUp()
        // Nil means nothing changed: redrawing would still cost the whole
        // interface a pass, and an @Observable assignment is not free.
        if let updated { snapshot = updated }
    }

    /// Asks, and says whether we were turned away — the caller backs off on
    /// true. Any trouble counts, not only `429`: a machine with no login and a
    /// machine off the network both want to be asked less, not more.
    private func askForLimits() async -> Bool {
        let reading = await UsageLimits.fetch()
        snapshot = await scanner.apply(limits: reading)

        return reading.trouble != nil
    }
}

/// The ledger, and the thread it is safe on.
///
/// An actor rather than a lock: the first pass reads a gigabyte and takes
/// seconds, and none of that may happen on the thread drawing the window. What
/// crosses back is the snapshot — a few dozen numbers — never the ledger.
private actor UsageScanner {
    private var ledger = UsageLedger()
    private var limits = UsageLimits.Reading()
    private var counted = false

    private let store = UsageStore()

    /// Whether anything has been counted since the last save. A save writes a
    /// megabyte or so; doing it on a tick that found nothing would be a
    /// megabyte to say nothing changed.
    private var unsaved = false

    /// Reads back what the last run counted.
    ///
    /// Returns nil when there is nothing saved — a first launch, a cleared
    /// file, or one written by another version. That is not a failure: the
    /// transcripts still say everything this file did.
    func restore() -> UsageSnapshot? {
        ledger = store.load()
        guard !ledger.isEmpty else { return nil }

        // What was saved may have gone stale while the app was closed: a record
        // from last week falls out of the horizon the moment it is loaded.
        ledger.prune(before: Date().addingTimeInterval(-UsageLedger.horizon))

        counted = true
        return snapshot()
    }

    func save() {
        guard unsaved else { return }
        unsaved = false

        try? store.save(ledger)
    }

    /// Reads whatever the agents have written since the last pass.
    ///
    /// Returns nil when nothing moved, which is the common case: the interface
    /// is left alone rather than redrawn over identical numbers.
    func catchUp() -> UsageSnapshot? {
        let root = SessionCatalog.defaultRoot

        let projects =
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        var changed = false

        // Every project on the machine, not only the ones open in Roost: the
        // five-hour window is spent by whatever ran in it, and a count that
        // left out the other windows would sit next to a percentage it
        // disagreed with.
        for project in projects {
            for transcript in UsageScan.transcripts(in: project) {
                let moved = ledger.absorb(
                    transcript: transcript.path,
                    session: transcript.session,
                    project: project.lastPathComponent
                )
                changed = changed || moved
            }
        }

        // The first pass reports even when it found nothing: "counting" and
        // "counted, and it is zero" are different things to say.
        guard changed || !counted else { return nil }

        counted = true
        unsaved = unsaved || changed

        return snapshot()
    }

    func apply(limits reading: UsageLimits.Reading) -> UsageSnapshot {
        // The last good answer survives one that brought nothing — see
        // [UsageLimits.Reading.keeping].
        limits = reading.keeping(limits)
        return snapshot()
    }

    private func snapshot() -> UsageSnapshot {
        ledger.snapshot(limits: limits, counting: !counted)
    }
}
