import Foundation
import Testing
@testable import RunnerCore

@Test func removedPreferencesDoNotPreventLoadingSavedRunners() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(root: root)
    try paths.prepare()
    let file = root.appendingPathComponent("runners.json")
    let saved = #"[{"id":"472574D8-CA3E-43D0-A955-67BEA58F8323","repository":"owner/repo","name":"Mac","label":"runner-test","githubID":21,"useHerd":true}]"#
    try Data(saved.utf8).write(to: file)
    let expected = try Runner(id: UUID(uuidString: "472574D8-CA3E-43D0-A955-67BEA58F8323")!,
                              repository: "owner/repo", name: "Mac", label: "runner-test", githubID: 21)
    #expect(try paths.load() == [expected])
    try paths.save([expected])
    #expect(try paths.load() == [expected])
    #expect(try !String(contentsOf: file, encoding: .utf8).contains("useHerd"))
}

@Test func environmentFiltersInheritedCredentialsAndUsesStandardPath() {
    let home = URL(fileURLWithPath: "/fixture home")
    let inherited = ["HOME": home.path, "USER": "fixture", "PATH": "/untrusted",
                     "GITHUB_TOKEN": "synthetic-management-token", "GH_TOKEN": "synthetic-token",
                     "CUSTOM_SECRET": "synthetic-secret"]
    let environment = RunnerProcess.environment(home: home, inherited: inherited)
    #expect(environment["PATH"] == "\(home.path)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(environment["HOME"] == home.path)
    #expect(environment["USER"] == "fixture")
    for key in ["GITHUB_TOKEN", "GH_TOKEN", "CUSTOM_SECRET"] {
        #expect(environment[key] == nil)
    }
    #expect(RunnerProcess.environment(home: home, inherited: environment) == environment)
}
