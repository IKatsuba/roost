import Foundation
import Testing

@testable import RoostCore

@Suite("session transcript")
struct TranscriptTests {
    /// The record shapes are taken from a real Claude Code file, not invented.
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-transcript-\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
        return url
    }

    private func assistant(_ blocks: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[\#(blocks)]}}"#
    }

    private func text(_ value: String) -> String {
        #"{"type":"text","text":"\#(value)"}"#
    }

    @Test("the agent's last message is the one taken")
    func lastMessage() throws {
        let file = try write([
            assistant(text("First answer")),
            #"{"type":"user","message":{"role":"user","content":"go ahead"}}"#,
            assistant(text("Which of the two do we take?")),
            #"{"type":"last-prompt","lastPrompt":"go ahead"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(Transcript.lastAgentMessage(at: file.path) == "Which of the two do we take?")
    }

    @Test("thinking and tool calls do not reach the card")
    func skipsNonSpeech() throws {
        let file = try write([
            assistant(text("Asking: should build be deleted?")),
            assistant(#"{"type":"thinking","thinking":"better make sure"}"#),
            assistant(#"{"type":"tool_use","name":"Bash","input":{}}"#),
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        // Otherwise the queue would hold the agent's thoughts instead of its
        // question.
        #expect(Transcript.lastAgentMessage(at: file.path) == "Asking: should build be deleted?")
    }

    @Test("a multiple-choice question outranks the preamble before it")
    func prefersAskedQuestion() throws {
        // The question arrives as a tool call rather than as text; what is on
        // screen at that moment is a dialog with options, and that is exactly
        // what is expected from the human.
        let file = try write([
            assistant(text("Hi! How can I help?")),
            assistant(
                text("Let me check.") + ","
                    + #"{"type":"tool_use","name":"AskUserQuestion","input":"#
                    + #"{"questions":[{"question":"What shall we do in this project?","header":"Task"}]}}"#
            ),
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(
            Transcript.lastAgentMessage(at: file.path) == "What shall we do in this project?"
        )
    }

    @Test("line breaks collapse into spaces")
    func flattensWhitespace() throws {
        let file = try write([assistant(text("Two lines:\\n\\n  - one\\n  - two"))])
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(Transcript.lastAgentMessage(at: file.path) == "Two lines: - one - two")
    }

    @Test("a line cut off at the start does not break parsing")
    func survivesTruncation() throws {
        let file = try write([
            String(repeating: "x", count: 4096),
            assistant(text("A whole record")),
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        // The tail of a file almost always begins mid-line — that line must
        // simply drop out without taking whole records with it.
        #expect(Transcript.lastAgentMessage(at: file.path, tail: 512) == "A whole record")
    }

    @Test("a message beyond the tail means no answer at all")
    func givesUpBeyondTail() throws {
        let file = try write([
            assistant(text("A whole record")),
            String(repeating: "x", count: 4096),
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        // This is what a huge tool result on top of a message looks like. There
        // is nothing to make up — the card takes its fallback.
        #expect(Transcript.lastAgentMessage(at: file.path, tail: 512) == nil)
        #expect(Transcript.lastAgentMessage(at: file.path) == "A whole record")
    }

    @Test("the invented name wins over the slug")
    func prefersAiTitle() throws {
        let file = try write([
            #"{"type":"agent-name","agentName":"roost-swiftui-workspace"}"#,
            assistant(text("Done")),
            #"{"type":"ai-title","aiTitle":"View switch in the window bar"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        // The slug lies higher up the file, and a walk from the end would reach
        // it first — but what a human reads is the invented name.
        #expect(Transcript.read(at: file.path).title == "View switch in the window bar")
        #expect(Transcript.read(at: file.path).message == "Done")
    }

    @Test("a name from a human outranks the invented one")
    func prefersCustomTitle() throws {
        let file = try write([
            #"{"type":"custom-title","customTitle":"Post-mortem"}"#,
            #"{"type":"ai-title","aiTitle":"View switch in the window bar"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        // `/rename` is the only way to name a session that started with "hi":
        // Claude Code invents a name from the first message only.
        #expect(Transcript.read(at: file.path).title == "Post-mortem")
    }

    @Test("the agent's slug is used when there is no name")
    func fallsBackToAgentName() throws {
        let file = try write([#"{"type":"agent-name","agentName":"roost-swiftui-workspace"}"#])
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(Transcript.read(at: file.path).title == "roost-swiftui-workspace")
    }

    @Test("no messages means no answer")
    func nothingToShow() throws {
        let file = try write([#"{"type":"queue-operation","operation":"add"}"#])
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(Transcript.lastAgentMessage(at: file.path) == nil)
        #expect(Transcript.lastAgentMessage(at: "/tmp/no-such-file.jsonl") == nil)
    }
}
