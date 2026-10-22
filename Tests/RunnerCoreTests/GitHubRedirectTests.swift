import Foundation
import Synchronization
import Testing
@testable import RunnerCore

private final class RepositoryRedirectProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let url = request.url!
        if url.path.hasPrefix("/repos/") {
            let destination = URL(string: "https://api.github.com/repositories/123/actions/runners"
                + (request.httpMethod == "DELETE" ? "/21" : ""))!
            var redirected = URLRequest(url: destination)
            redirected.httpMethod = request.httpMethod
            let response = HTTPURLResponse(url: url, statusCode: request.httpMethod == "DELETE" ? 307 : 301,
                                           httpVersion: nil, headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
        let response = HTTPURLResponse(url: url, statusCode: authorized ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"runners":[{"id":21,"name":"Mac","status":"offline","busy":false}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func removalKeepsAuthenticationWhenARepositoryWasRenamed() async throws {
    RepositoryRedirectProtocol.requests.withLock { $0 = [] }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RepositoryRedirectProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let github = GitHub(session: session, token: "fixture-token")
    let runner = try Runner(repository: "fixture/old", name: "Mac", label: "test", githubID: 21)

    try await github.remove(runner)

    let requests = RepositoryRedirectProtocol.requests.withLock { $0 }
    #expect(requests.map(\.httpMethod) == ["GET", "GET", "DELETE", "DELETE"])
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
}

@Test(arguments: [
    ("https://api.github.com/repositories/123", true),
    ("https://api.github.com:443/repositories/123", true),
    ("http://api.github.com/repositories/123", false),
    ("https://example.com/", false),
    ("https://api.github.com.example.com/", false),
    ("https://api.github.com:444/", false),
    ("https://user:password@api.github.com/", false)
])
func redirectsOnlySendCredentialsToGitHubsHTTPSAPI(destination: String, allowed: Bool) async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let originalURL = URL(string: "https://api.github.com/repos/fixture/old/actions/runners/21")!
    var original = URLRequest(url: originalURL)
    original.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
    let task = session.dataTask(with: original)
    var redirected = URLRequest(url: URL(string: destination)!)
    redirected.httpMethod = "DELETE"
    let response = HTTPURLResponse(url: originalURL, statusCode: 307, httpVersion: nil, headerFields: nil)!

    let request = await GitHubRedirectDelegate().urlSession(session, task: task,
        willPerformHTTPRedirection: response, newRequest: redirected)

    #expect((request != nil) == allowed)
    if allowed {
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request?.httpMethod == "DELETE")
    }
}
