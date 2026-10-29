import Foundation
import Testing
@testable import LocalFlow

@Suite("Connectors: which tools ask first")
struct ConnectorPolicyTests {
    private func decide(_ tool: String, grants: Set<String> = [], title: String? = nil,
                        input: AgentJSON = ["owner": "o", "repo": "r"]) -> AgentDecision {
        AgentPolicy.decide(toolName: tool, input: input, grants: grants, targetTitle: title, frontApp: nil,
                           home: "/Users/me")
    }

    @Test("a connector's read-like tools just run", arguments: [
        "mcp__github__get_file_contents", "mcp__github__list_issues", "mcp__github__search_code", "mcp__github__get_me",
        "mcp__linear__listIssues", "mcp__notes__read-page", "mcp__docs__fetch", "mcp__x__find_user", "mcp__x__view_repo",
        "mcp__x__describe_table", "mcp__x__show_status", "mcp__github__get_workflow_run", "mcp__x__GetItem",
        "mcp__x__getHTMLPage", "mcp__github__list_commits",
    ])
    func readLikeRuns(tool: String) {
        #expect(decide(tool) == .allow)
    }

    @Test("everything else asks, named in plain words", arguments: [
        ("mcp__github__create_pull_request", "Use github: create pull request", "connector:github:create_pull_request"),
        ("mcp__github__mergePullRequest", "Use github: merge pull request", "connector:github:mergePullRequest"),
        ("mcp__other__send", "Use other: send", "connector:other:send"),
        ("mcp__github__push_files", "Use github: push files", "connector:github:push_files"),
        ("mcp__github__issue_read", "Use github: issue read", "connector:github:issue_read"),
        ("mcp__x__get_or_create_issue", "Use x: get or create issue", "connector:x:get_or_create_issue"),
        ("mcp__x__find-and-replace", "Use x: find and replace", "connector:x:find-and-replace"),
        ("mcp__x__getter", "Use x: getter", "connector:x:getter"),
        ("mcp__jira-2__runJQL", "Use jira-2: run jql", "connector:jira-2:runJQL"),
        ("mcp__x__getURLDelete", "Use x: get url delete", "connector:x:getURLDelete"),
        ("mcp__x__get_and_run_job", "Use x: get and run job", "connector:x:get_and_run_job"),
        ("mcp__x__fetch_then_wipe", "Use x: fetch then wipe", "connector:x:fetch_then_wipe"),
        ("mcp__x__list_or_install", "Use x: list or install", "connector:x:list_or_install"),
        ("mcp__x__find_kill", "Use x: find kill", "connector:x:find_kill"),
    ])
    func writeLikeAsks(tool: String, summary: String, key: String) {
        #expect(decide(tool) == .ask(summary: summary, grantKey: key))
    }

    @Test("allowing one for the task lets the next one of that tool through, and only that one")
    func grants() {
        let key = "connector:github:create_issue"
        #expect(AgentApproval.canGrant(key))
        #expect(decide("mcp__github__create_issue", grants: [key]) == .allow)
        #expect(decide("mcp__github__close_issue", grants: [key]) != .allow)
        #expect(decide("mcp__gitlab__create_issue", grants: [key]) != .allow)
    }

    @Test("LocalFlow's own screen tools are unaffected")
    func screenToolsUnaffected() {
        #expect(decide("mcp__localflow__screenshot") == .allow)
        #expect(decide("mcp__localflow__click", input: ["x": 1, "y": 2]) == .allow)
        #expect(decide("mcp__localflow__click", input: ["x": 1, "y": 2, "irreversible": true])
            == .ask(summary: "Click at (1, 2)", grantKey: "click:irreversible"))
        #expect(decide("mcp__localflow__click", title: "Send", input: ["x": 1, "y": 2])
            == .ask(summary: "Click “Send”", grantKey: "click:send"))
        #expect(decide("mcp__localflow__get_secrets")
            == .ask(summary: "Use mcp__localflow__get_secrets", grantKey: "tool:mcp__localflow__get_secrets"))
    }

    @Test("names that aren't a connector's tool are asked about as before", arguments: ["mcp__github__", "mcp____get"])
    func malformedNames(tool: String) {
        #expect(decide(tool) == .ask(summary: "Use \(tool)", grantKey: "tool:\(tool)"))
    }

    @Test("hidden characters in a tool's name show on the card")
    func hiddenCharacters() {
        guard case .ask(let summary, _) = decide("mcp__x__send\u{202E}gnihton") else {
            Issue.record("expected to ask")
            return
        }
        #expect(!summary.unicodeScalars.contains("\u{202E}"))
    }
}
