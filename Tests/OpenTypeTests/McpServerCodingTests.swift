import XCTest
@testable import OpenType

/// Stage-1 (red) tests for P2-13's Swift-side wire models: the Settings
/// "MCP 服务器" panel that finally makes `OPENTYPE_MCP_SERVERS` reachable from
/// a packaged app.
///
/// These pin the payload shapes only — decoding `GET /config/mcp`,
/// `POST`/`PUT /config/mcp[/:name]` and `POST /config/mcp/test`, and encoding
/// the request bodies. No SwiftUI view behavior is asserted here.
///
/// New types required in `Models.swift` for this to compile:
///
///   * `McpTransport` — `"stdio"` / `"http"`, the two server kinds.
///   * `McpConfigSource` — `"saved"` / `"env"`; which of the two config
///     sources the sidecar is actually serving (saved config wins; the env
///     var is the zero-config dev fallback).
///   * `McpServerSummary` — one server as the sidecar reports it. Secrets
///     arrive **only** as `envMasked`/`headersMasked`; there is deliberately
///     no `env`/`headers` property to decode into, so a real token cannot
///     reach Swift even if a future sidecar bug tried to send one.
///   * `McpConfigSummary` — the list response.
///   * `McpServerRequest` — the create/update body, carrying *real*
///     `env`/`headers` values on the way out.
///   * `McpTestResultSummary` / `McpToolSummary` — the Test Connection
///     result, i.e. which tools this server would hand the agent.
///
/// Conformances the assertions below require, beyond `Codable`:
/// `McpServerSummary` and `McpToolSummary` are `Identifiable` (both are
/// rendered as list rows, and `id` is asserted directly), `McpToolSummary` is
/// `Equatable` (an empty tool list is compared as a value), and
/// `McpTransport`/`McpConfigSource` are `Equatable` raw-value enums.
///
/// Decoding goes through `SidecarClient.decodeResponse(fromRawOutput:)`, the
/// same seam `MemoryTermCodingTests` uses, so this exercises the real decode
/// path rather than a bespoke one.
final class McpServerCodingTests: XCTestCase {

    // MARK: - GET /config/mcp

    /// A saved stdio server round-trips its command line and its masked env.
    /// The mask, not the token, is what the panel renders.
    func testConfigSummaryDecodesSavedStdioServer() throws {
        let json = """
        {"configured":true,"source":"saved","servers":[
          {"name":"filesystem","transport":"stdio","command":"npx",
           "args":["-y","@modelcontextprotocol/server-filesystem","/tmp"],
           "envMasked":{"GITHUB_TOKEN":"ghp*************lue"}}
        ]}
        """

        let summary: McpConfigSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertTrue(summary.configured)
        XCTAssertEqual(summary.source, .saved)

        let server = try XCTUnwrap(summary.servers.first)
        XCTAssertEqual(server.name, "filesystem")
        XCTAssertEqual(server.transport, .stdio)
        XCTAssertEqual(server.command, "npx")
        XCTAssertEqual(server.args, ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        XCTAssertEqual(server.envMasked, ["GITHUB_TOKEN": "ghp*************lue"])
        XCTAssertNil(server.url)
        XCTAssertNil(server.headersMasked)
    }

    func testConfigSummaryDecodesSavedHttpServer() throws {
        let json = """
        {"configured":true,"source":"saved","servers":[
          {"name":"linear","transport":"http","url":"https://mcp.linear.app/mcp",
           "headersMasked":{"Authorization":"Bea***************lue"}}
        ]}
        """

        let summary: McpConfigSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        let server = try XCTUnwrap(summary.servers.first)
        XCTAssertEqual(server.transport, .http)
        XCTAssertEqual(server.url, "https://mcp.linear.app/mcp")
        XCTAssertEqual(server.headersMasked, ["Authorization": "Bea***************lue"])
        XCTAssertNil(server.command)
    }

    /// An empty list is the normal first-run state, not an error.
    func testConfigSummaryDecodesTheUnconfiguredEmptyCase() throws {
        let json = #"{"configured":false,"source":"env","servers":[]}"#

        let summary: McpConfigSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertFalse(summary.configured)
        XCTAssertEqual(summary.source, .env)
        XCTAssertTrue(summary.servers.isEmpty)
    }

    /// Servers coming from `OPENTYPE_MCP_SERVERS` are shown, but
    /// `configured` stays false — an ambient env var is a dev fallback, never
    /// a user decision, so the panel must present those rows as inherited
    /// rather than as the user's saved config.
    func testEnvSourcedServersAreListedWhileStillReportingUnconfigured() throws {
        let json = """
        {"configured":false,"source":"env","servers":[
          {"name":"envserver","transport":"stdio","command":"node","args":["s.js"]}
        ]}
        """

        let summary: McpConfigSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertFalse(summary.configured)
        XCTAssertEqual(summary.source, .env)
        XCTAssertEqual(summary.servers.map(\.name), ["envserver"])
    }

    /// The server name is the id the routes address (`PUT`/`DELETE
    /// /config/mcp/:name`), so it must also be SwiftUI's row identity.
    func testServerIdentityIsItsName() throws {
        let json = """
        {"configured":true,"source":"saved","servers":[
          {"name":"a","transport":"stdio","command":"npx","args":[]},
          {"name":"b","transport":"stdio","command":"bun","args":[]}
        ]}
        """

        let summary: McpConfigSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(summary.servers.map(\.id), ["a", "b"])
    }

    // MARK: - POST/PUT response

    private struct McpServerMutationBody: Decodable { let server: McpServerSummary }

    /// Create and update both answer with the resulting server, so the panel
    /// refreshes one row instead of refetching the whole list.
    func testMutationResponseDecodesTheResultingServer() throws {
        let json = """
        {"server":{"name":"filesystem","transport":"stdio","command":"bun","args":["run","s.ts"],
                   "envMasked":{"GITHUB_TOKEN":"ghp*************lue"}}}
        """

        let body: McpServerMutationBody = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(body.server.name, "filesystem")
        XCTAssertEqual(body.server.command, "bun")
        XCTAssertEqual(body.server.envMasked?["GITHUB_TOKEN"], "ghp*************lue")
    }

    // MARK: - POST /config/mcp/test

    /// The point of Test Connection is showing the user *which tools* this
    /// server would hand the agent — an unsandboxed capability grant, so the
    /// list is the decision-relevant part, not decoration.
    func testTestResultDecodesTheExposedToolList() throws {
        let json = """
        {"success":true,"tools":[
          {"name":"read_file","description":"Read a file"},
          {"name":"write_file","description":"Write a file"}
        ]}
        """

        let result: McpTestResultSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertTrue(result.success)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.tools?.map(\.name), ["read_file", "write_file"])
        XCTAssertEqual(result.tools?.first?.description, "Read a file")
        XCTAssertEqual(result.tools?.map(\.id), ["read_file", "write_file"])
    }

    /// A tool with no description still decodes; MCP servers are not required
    /// to supply one.
    func testTestResultDecodesAToolWithoutADescription() throws {
        let json = #"{"success":true,"tools":[{"name":"ping"}]}"#

        let result: McpTestResultSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertEqual(result.tools?.count, 1)
        XCTAssertNil(result.tools?.first?.description)
    }

    /// A server that connects but exposes nothing is a success with an empty
    /// list — distinguishable from a failure, and from "tools omitted".
    func testTestResultDistinguishesAnEmptyToolListFromAFailure() throws {
        let json = #"{"success":true,"tools":[]}"#

        let result: McpTestResultSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.tools, [])
    }

    func testTestResultDecodesAFailureWithNoToolList() throws {
        let json = #"{"success":false,"error":"spawn npx ENOENT"}"#

        let result: McpTestResultSummary = try SidecarClient.decodeResponse(fromRawOutput: json)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "spawn npx ENOENT")
        XCTAssertNil(result.tools)
    }

    // MARK: - Request bodies

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A stdio request carries the *real* env values (this is the one
    /// direction secrets travel in the clear, over the local Unix socket) and
    /// omits every http-only field rather than sending it as null — a null
    /// `url` would read on the sidecar side as "url supplied but empty" and
    /// 400 a perfectly valid stdio server.
    func testStdioRequestEncodesCommandArgsAndRealEnvOnly() throws {
        let object = try encodedObject(
            McpServerRequest(
                name: "filesystem",
                transport: .stdio,
                command: "npx",
                args: ["-y", "server-filesystem"],
                env: ["GITHUB_TOKEN": "ghp_realsecretvalue"],
                url: nil,
                headers: nil
            )
        )

        XCTAssertEqual(object["name"] as? String, "filesystem")
        XCTAssertEqual(object["transport"] as? String, "stdio")
        XCTAssertEqual(object["command"] as? String, "npx")
        XCTAssertEqual(object["args"] as? [String], ["-y", "server-filesystem"])
        XCTAssertEqual(object["env"] as? [String: String], ["GITHUB_TOKEN": "ghp_realsecretvalue"])
        XCTAssertEqual(Set(object.keys), ["name", "transport", "command", "args", "env"])
    }

    func testHttpRequestEncodesUrlAndHeadersOnly() throws {
        let object = try encodedObject(
            McpServerRequest(
                name: "linear",
                transport: .http,
                command: nil,
                args: nil,
                env: nil,
                url: "https://mcp.linear.app/mcp",
                headers: ["Authorization": "Bearer realtokenvalue"]
            )
        )

        XCTAssertEqual(object["transport"] as? String, "http")
        XCTAssertEqual(object["url"] as? String, "https://mcp.linear.app/mcp")
        XCTAssertEqual(
            object["headers"] as? [String: String],
            ["Authorization": "Bearer realtokenvalue"]
        )
        XCTAssertEqual(Set(object.keys), ["name", "transport", "url", "headers"])
    }

    /// `PUT /config/mcp/:name` replaces rather than patches, and the sidecar
    /// reads an omitted `env` the same way it reads an empty one — both clear
    /// it (see `mcpConfigRoutes.test.ts`; the mask round-trip, not field
    /// omission, is how an untouched secret survives a write). What this pins
    /// is the encoder: an empty dictionary goes out as `{}` and a nil one is
    /// left out of the JSON entirely, so neither is ever written as `null`.
    /// A null would be a third state the sidecar has to special-case, and on
    /// `url`/`command` it reads as "supplied but empty" — a 400 on a server
    /// that was perfectly valid.
    func testEmptyEnvIsSentWhileNilEnvIsOmitted() throws {
        let cleared = try encodedObject(
            McpServerRequest(
                name: "filesystem",
                transport: .stdio,
                command: "npx",
                args: [],
                env: [:],
                url: nil,
                headers: nil
            )
        )
        XCTAssertEqual(cleared["env"] as? [String: String], [:])
        XCTAssertEqual(cleared["args"] as? [String], [])

        let untouched = try encodedObject(
            McpServerRequest(
                name: "filesystem",
                transport: .stdio,
                command: "npx",
                args: [],
                env: nil,
                url: nil,
                headers: nil
            )
        )
        XCTAssertNil(untouched["env"])
    }

    /// The panel's edit form is populated from `envMasked`, so an untouched
    /// field is submitted as its mask. That is a supported round-trip — the
    /// sidecar resolves a value equal to the stored mask back to the stored
    /// secret — and the Swift model must therefore send the mask through
    /// unchanged rather than trying to be clever and drop it.
    func testAMaskedEnvValueIsSubmittedVerbatim() throws {
        let object = try encodedObject(
            McpServerRequest(
                name: "filesystem",
                transport: .stdio,
                command: "npx",
                args: [],
                env: ["GITHUB_TOKEN": "ghp*************lue"],
                url: nil,
                headers: nil
            )
        )

        XCTAssertEqual(
            object["env"] as? [String: String],
            ["GITHUB_TOKEN": "ghp*************lue"]
        )
    }
}
