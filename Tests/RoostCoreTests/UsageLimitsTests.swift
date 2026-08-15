import Foundation
import Testing

@testable import RoostCore

@Suite("Limits")
struct UsageLimitsTests {
    private func parse(_ json: String) -> [LimitWindow] {
        let object =
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return UsageLimits.windows(in: object)
    }

    @Test func readsTheTwoPlainWindows() {
        let windows = parse(
            """
            {"five_hour": {"utilization": 62, "resets_at": "2026-08-12T22:00:00Z"},
             "seven_day": {"utilization": 54, "resets_at": "2026-08-17T09:00:00Z"}}
            """
        )

        #expect(windows.count == 2)
        #expect(windows[0].kind == .session)
        #expect(windows[0].usedPercent == 62)
        #expect(windows[0].title == "5H")
        #expect(windows[0].resetsAt == UsageScan.date(from: "2026-08-12T22:00:00Z"))
        #expect(windows[1].kind == .week)
        #expect(windows[1].usedPercent == 54)
    }

    /// A plan can be out of Opus while the plain week still has room, so the
    /// per-model ceilings are their own windows rather than a footnote.
    @Test func readsThePerModelWeeks() {
        let windows = parse(
            """
            {"seven_day": {"utilization": 10},
             "seven_day_opus": {"utilization": 88},
             "seven_day_sonnet": {"utilization": 3}}
            """
        )

        #expect(windows.map(\.title) == ["7D", "7D OPUS", "7D SONNET"])
        #expect(windows.first { $0.label == "opus" }?.usedPercent == 88)
    }

    /// The set of windows differs by plan and grows over time. One that is not
    /// there is not a zero — an empty bar is a claim of its own.
    @Test func leavesOutWindowsTheAccountDoesNotHave() {
        #expect(parse(#"{"five_hour": {"utilization": 5}}"#).map(\.title) == ["5H"])
        #expect(parse("{}").isEmpty)
        #expect(parse(#"{"five_hour": {"resets_at": "2026-08-12T22:00:00Z"}}"#).isEmpty)
    }

    /// A window that arrives after this was written costs nothing rather than
    /// breaking the ones beside it.
    @Test func ignoresShapesItDoesNotRecognise() {
        let windows = parse(
            """
            {"five_hour": {"utilization": 5},
             "seven_day_future_thing": "not an object",
             "extra_usage": {"is_enabled": false}}
            """
        )

        #expect(windows.map(\.title) == ["5H"])
    }

    /// The order is fixed, or the row would rearrange itself under the cursor
    /// on every poll.
    @Test func keepsAStableOrder() {
        let json = """
            {"seven_day_sonnet": {"utilization": 3}, "seven_day_opus": {"utilization": 88},
             "seven_day": {"utilization": 10}, "five_hour": {"utilization": 62}}
            """

        // Dictionary iteration is unordered, so the same body is read a few
        // times: an order that only happens to hold is not one.
        for _ in 0..<20 {
            #expect(parse(json).map(\.title) == ["5H", "7D", "7D OPUS", "7D SONNET"])
        }
    }

    @Test func clampsAPercentageOutOfRange() {
        #expect(parse(#"{"five_hour": {"utilization": 140}}"#).first?.usedPercent == 100)
        #expect(parse(#"{"five_hour": {"utilization": -3}}"#).first?.usedPercent == 0)
    }

    @Test func readsAWholeNumberPercentage() {
        #expect(parse(#"{"five_hour": {"utilization": 62}}"#).first?.usedPercent == 62)
        #expect(parse(#"{"five_hour": {"utilization": 62.5}}"#).first?.usedPercent == 62.5)
    }

    // MARK: - Credentials

    @Test func findsTheTokenInTheCredentialsShape() {
        let json = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-abc", "expiresAt": 1}}"#
        #expect(UsageLimits.token(inCredentials: Data(json.utf8)) == "sk-ant-oat01-abc")
    }

    @Test func findsNoTokenInSomethingElse() {
        #expect(UsageLimits.token(inCredentials: Data(#"{"claudeAiOauth": {}}"#.utf8)) == nil)
        #expect(UsageLimits.token(inCredentials: Data(#"{"accessToken": "x"}"#.utf8)) == nil)
        #expect(UsageLimits.token(inCredentials: Data(#"{"claudeAiOauth": {"accessToken": ""}}"#.utf8)) == nil)
        #expect(UsageLimits.token(inCredentials: Data("not json".utf8)) == nil)
    }

    // MARK: - Holding on to the last good answer

    /// Being turned away is the ordinary case at this address — Claude Code
    /// asks at it too — and it must not wipe the percentages.
    @Test func keepsTheWindowsAnAskWasRefused() {
        let good = UsageLimits.Reading(
            windows: [LimitWindow(kind: .session, usedPercent: 42)],
            at: Date(timeIntervalSince1970: 1000)
        )
        let refused = UsageLimits.Reading(
            windows: [],
            at: Date(timeIntervalSince1970: 1060),
            trouble: .throttled
        )

        let shown = refused.keeping(good)

        #expect(shown.windows.map(\.usedPercent) == [42])
        #expect(shown.trouble == nil)

        // The age is the good answer's, not the refusal's — that is what makes
        // the figures go stale on time rather than never.
        #expect(shown.at == good.at)
    }

    /// Past the staleness mark the old figures stop being worth standing
    /// behind, and the trouble is told after all.
    @Test func tellsTheTroubleOnceTheFiguresAreStale() {
        let good = UsageLimits.Reading(
            windows: [LimitWindow(kind: .session, usedPercent: 42)],
            at: Date(timeIntervalSince1970: 1000)
        )
        let refused = UsageLimits.Reading(
            windows: [],
            at: Date(timeIntervalSince1970: 1000 + 16 * 60),
            trouble: .throttled
        )

        #expect(refused.keeping(good).trouble == .throttled)
        #expect(refused.keeping(good).windows.isEmpty)
    }

    /// A good answer always wins, and a refusal with nothing behind it is
    /// still a refusal — a machine that has never logged in has to be told so.
    @Test func replacesTheReadingWhenThereIsAnAnswer() {
        let old = UsageLimits.Reading(
            windows: [LimitWindow(kind: .session, usedPercent: 42)],
            at: Date(timeIntervalSince1970: 1000)
        )
        let fresh = UsageLimits.Reading(
            windows: [LimitWindow(kind: .session, usedPercent: 71)],
            at: Date(timeIntervalSince1970: 1060)
        )

        #expect(fresh.keeping(old).windows.map(\.usedPercent) == [71])
        #expect(UsageLimits.Reading(trouble: .noCredentials).keeping(UsageLimits.Reading()).trouble
            == .noCredentials)
    }

    /// `CLAUDE_CONFIG_DIR` moves the whole configuration, credentials with it.
    @Test func followsTheConfiguredDirectory() {
        let moved = UsageLimits.credentialsFile(environment: ["CLAUDE_CONFIG_DIR": "/tmp/elsewhere"])
        #expect(moved.path == "/tmp/elsewhere/.credentials.json")

        let plain = UsageLimits.credentialsFile(environment: [:])
        #expect(plain.path.hasSuffix("/.claude/.credentials.json"))
    }
}
