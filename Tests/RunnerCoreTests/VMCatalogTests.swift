import Foundation
import Testing
@testable import RunnerCore

private func vmCatalogGit(_ arguments: [String], at directory: URL) async throws -> String {
    try await RunnerProcess.command(URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
        directory: directory, extraEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test(arguments: ["fresh", "current", "invalid", "parent-repository", "dangling-link", "download-failure"], ["/bin/bash", "/bin/zsh"])
func vmCatalogPreparationPreservesExistingDataAndStagesAShallowClone(state: String, shell: String) async throws {
    let files = FileManager.default
    let root = URL.temporaryDirectory.appendingPathComponent("comet-catalog-\(UUID())", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let prefix = root.appendingPathComponent("homebrew")
    let catalog = prefix.appendingPathComponent("Library/Taps/homebrew/homebrew-core")
    let parent = catalog.deletingLastPathComponent()
    let formula = "Formula/fixture.rb"
    _ = try await vmCatalogGit(["init", "--quiet", "--initial-branch=main", source.path], at: root)
    try files.createDirectory(at: source.appendingPathComponent("Formula"), withIntermediateDirectories: true)
    for revision in 1...2 {
        try Data("fixture revision \(revision)\n".utf8).write(to: source.appendingPathComponent(formula))
        _ = try await vmCatalogGit(["add", formula], at: source)
        _ = try await vmCatalogGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--quiet", "-m", "Fixture \(revision)"], at: source)
    }
    let expectedHEAD = try await vmCatalogGit(["rev-parse", "HEAD"], at: source)
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    if state == "current" {
        _ = try await vmCatalogGit(["clone", "--quiet", "--depth", "1", "--branch", "main",
            source.absoluteString, catalog.path], at: root)
        try Data("local changes\n".utf8).write(to: catalog.appendingPathComponent(formula))
        try Data("untracked\n".utf8).write(to: catalog.appendingPathComponent("keep.txt"))
        try Data("new remote revision\n".utf8).write(to: source.appendingPathComponent(formula))
        _ = try await vmCatalogGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--quiet", "-am", "New remote revision"], at: source)
    } else if state == "invalid" || state == "parent-repository" {
        if state == "parent-repository" {
            _ = try await vmCatalogGit(["init", "--quiet", "--initial-branch=main", prefix.path], at: root)
            try Data("parent repository\n".utf8).write(to: prefix.appendingPathComponent("parent.txt"))
            _ = try await vmCatalogGit(["add", "parent.txt"], at: prefix)
            _ = try await vmCatalogGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "--quiet", "-m", "Parent repository"], at: prefix)
        }
        try files.createDirectory(at: catalog, withIntermediateDirectories: true)
        try Data("preserved\n".utf8).write(to: catalog.appendingPathComponent("keep.txt"))
        if state == "invalid" {
            try files.createDirectory(at: catalog.appendingPathComponent(".git"), withIntermediateDirectories: true)
        } else {
            let discovered = URL(fileURLWithPath: try await vmCatalogGit(["rev-parse", "--show-toplevel"], at: catalog))
            #expect(discovered.resolvingSymlinksInPath().path == prefix.resolvingSymlinksInPath().path)
        }
    } else if state == "dangling-link" {
        try files.createSymbolicLink(at: catalog, withDestinationURL: root.appendingPathComponent("missing-target"))
    }
    let remote = state == "download-failure" ? root.appendingPathComponent("missing.git") : source
    let script = VMTools.catalogScript
        .replacingOccurrences(of: "/opt/homebrew/Library/Taps/homebrew/homebrew-core", with: catalog.path)
        .replacingOccurrences(of: "https://github.com/Homebrew/homebrew-core.git", with: remote.absoluteString)
    let succeeds = state == "fresh" || state == "current"
    do {
        _ = try await RunnerProcess.command(URL(fileURLWithPath: shell), arguments: ["-c", script],
            directory: root, extraEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"])
        #expect(succeeds)
    } catch {
        #expect(!succeeds)
        #expect(error is RunnerError)
    }

    if succeeds {
        #expect(try await vmCatalogGit(["rev-parse", "HEAD"], at: catalog) == expectedHEAD)
        #expect(try await vmCatalogGit(["rev-list", "--count", "HEAD"], at: catalog) == "1")
        #expect(try await vmCatalogGit(["rev-parse", "--is-shallow-repository"], at: catalog) == "true")
        #expect(try await vmCatalogGit(["symbolic-ref", "--short", "HEAD"], at: catalog) == "main")
        #expect(try String(contentsOf: catalog.appendingPathComponent(formula), encoding: .utf8)
            == (state == "current" ? "local changes\n" : "fixture revision 2\n"))
        if state == "current" {
            #expect(try String(contentsOf: catalog.appendingPathComponent("keep.txt"), encoding: .utf8) == "untracked\n")
        } else {
            #expect(try files.attributesOfItem(atPath: catalog.path)[.posixPermissions] as? Int == 0o755)
            #expect(try files.attributesOfItem(atPath: catalog.appendingPathComponent(formula).path)[.posixPermissions] as? Int == 0o644)
        }
    } else if state == "invalid" || state == "parent-repository" {
        #expect(try String(contentsOf: catalog.appendingPathComponent("keep.txt"), encoding: .utf8) == "preserved\n")
        #expect(try files.contentsOfDirectory(atPath: catalog.path).sorted()
            == (state == "invalid" ? [".git", "keep.txt"] : ["keep.txt"]))
    } else if state == "dangling-link" {
        #expect(try files.destinationOfSymbolicLink(atPath: catalog.path) == root.appendingPathComponent("missing-target").path)
        #expect(!files.fileExists(atPath: root.appendingPathComponent("missing-target").path))
    } else {
        #expect(!files.fileExists(atPath: catalog.path))
    }
    #expect(try files.contentsOfDirectory(atPath: parent.path) == (state == "download-failure" ? [] : ["homebrew-core"]))
}
