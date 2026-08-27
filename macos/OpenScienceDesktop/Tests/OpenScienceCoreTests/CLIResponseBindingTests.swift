#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class CLIResponseBindingTests: XCTestCase {
        func testPlanBindsResponsePathAndPersistedPlanContent() async throws {
            let root = try makeSecurityTestDirectory("plan-binding")
            defer { try? FileManager.default.removeItem(at: root) }
            let output = root.appendingPathComponent("plan.json")
            let executable = root.appendingPathComponent("plan")
            let plan = #"{"plan_id":"plan-1","steps":[]}"#
            try writeExecutable(
                "printf '%s\\n' '\(plan)' > '\(output.path)'; printf '{\"request\":{},\"plan\":%s,\"output\":\"/wrong/plan.json\"}\\n' '\(plan)'",
                to: executable
            )
            let invocation = CLIInvocation(
                executableURL: executable,
                arguments: ["plan", "--output", output.path, "--json", "--", "long question"],
                workingDirectory: root
            )
            await assertResponseShapeFailure(invocation)

            try writeExecutable(
                "printf '%s\\n' '{\"plan_id\":\"different\",\"steps\":[]}' > '\(output.path)'; printf '{\"request\":{},\"plan\":%s,\"output\":\"\(output.path)\"}\\n' '\(plan)'",
                to: executable
            )
            await assertResponseShapeFailure(invocation)
        }

        func testCancelAndExportBindRequestedTargetsAndPositiveSize() async throws {
            let root = try makeSecurityTestDirectory("target-binding")
            defer { try? FileManager.default.removeItem(at: root) }
            let run = root.appendingPathComponent("run-target", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
            let cancel = root.appendingPathComponent("cancel")
            try writeExecutable(
                "printf '{\"run_directory\":\"/wrong/run\",\"requested_at\":\"2026-08-21T00:00:00Z\"}\\n'",
                to: cancel
            )
            await assertResponseShapeFailure(
                CLIInvocation(
                    executableURL: cancel,
                    arguments: ["cancel", run.path, "--json"],
                    workingDirectory: root
                ))

            let output = root.appendingPathComponent("bundle.zip")
            let export = root.appendingPathComponent("export")
            try writeExecutable(
                "printf x > '\(output.path)'; printf '{\"output\":\"/wrong/bundle.zip\",\"size\":1}\\n'",
                to: export
            )
            await assertResponseShapeFailure(
                CLIInvocation(
                    executableURL: export,
                    arguments: ["export", run.path, "--output", output.path, "--json"],
                    workingDirectory: root
                ))

            try writeExecutable(
                "printf '{\"output\":\"\(output.path)\",\"size\":0}\\n'",
                to: export
            )
            await assertResponseShapeFailure(
                CLIInvocation(
                    executableURL: export,
                    arguments: ["export", run.path, "--output", output.path, "--json"],
                    workingDirectory: root
                ))
        }

        private func assertResponseShapeFailure(_ invocation: CLIInvocation) async {
            do {
                _ = try await OpenScienceCLIClient().execute(invocation)
                XCTFail("Expected response binding rejection")
            } catch let error as CLIProtocolError {
                guard case .responseShape = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
#endif
