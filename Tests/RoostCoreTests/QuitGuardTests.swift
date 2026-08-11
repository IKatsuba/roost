import Testing

@testable import RoostCore

@Suite("quit guard")
struct QuitGuardTests {
    @Test("nothing is asked when no agent is working")
    func silentWithoutWork() {
        #expect(QuitGuard.prompt(working: []) == nil)
    }

    @Test("one agent is spoken of in the singular")
    func singular() {
        let prompt = QuitGuard.prompt(working: ["roost · fix the parser"])
        #expect(prompt?.title == "quit while an agent is working?")
        #expect(prompt?.body.contains("roost · fix the parser") == true)
    }

    @Test("every name is listed, not just counted")
    func listsNames() {
        let names = ["a", "b", "c"]
        let prompt = QuitGuard.prompt(working: names)
        #expect(prompt?.title == "quit while 3 agents are working?")
        for name in names {
            #expect(prompt?.body.contains(name) == true)
        }
        #expect(prompt?.body.contains("more") == false)
    }

    @Test("a long list is cut off and the rest counted")
    func countsTheTail() {
        let names = (1...9).map { "session \($0)" }
        let prompt = QuitGuard.prompt(working: names)
        #expect(prompt?.body.contains("session \(QuitGuard.maxNames)") == true)
        #expect(prompt?.body.contains("session \(QuitGuard.maxNames + 1)") == false)
        #expect(prompt?.body.contains("and 3 more") == true)
    }
}
