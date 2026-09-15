import Foundation
import os

//  SelfTest.swift
//  Seal
//
//  A SMALL TEST HARNESS THAT LIVES INSIDE THE APP TARGET.
//
//  Seal.xcodeproj has no test target, and adding one means editing the
//  project file, which the house rules forbid doing by hand. So the tests
//  for the cryptographic layer, the release state machine and the security
//  fixes are ordinary Swift files under Seal/, compiled into the app, and run
//  by `SelfTest.runAll()`:
//
//    - automatically at launch in DEBUG builds (SealApp.swift), with every
//      failure logged to the `selftest` os-log category and asserted on;
//    - on demand from the debug Time Travel screen, which lists failures.
//
//  When a real XCTest target is added, each suite below moves across with
//  one mechanical change: `context.check(cond, name)` becomes `XCTAssert`.
//  Until then this is what keeps "fully unit tested" from being a sentence
//  in a document.
//
//  Suites register themselves in `SelfTestRegistry.suites`. Keep them pure:
//  no network, no keychain writes outside a namespaced test key, no clock
//  other than a `SimulatedClock`.

enum SelfTest {

    struct Failure: Identifiable, Hashable {
        let id = UUID()
        let suite: String
        let name: String
        let detail: String
    }

    struct Report: Equatable {
        var checks = 0
        var failures: [Failure] = []
        var passed: Bool { failures.isEmpty }

        static func == (a: Report, b: Report) -> Bool {
            a.checks == b.checks && a.failures == b.failures
        }
    }

    final class Context {
        let suite: String
        private(set) var checks = 0
        private(set) var failures: [Failure] = []

        init(suite: String) { self.suite = suite }

        @discardableResult
        func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") -> Bool {
            checks += 1
            if !condition {
                failures.append(Failure(suite: suite, name: name, detail: detail()))
            }
            return condition
        }

        func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
            check(actual == expected, name, "expected \(expected), got \(actual)")
        }

        func fail(_ name: String, _ detail: String = "") {
            checks += 1
            failures.append(Failure(suite: suite, name: name, detail: detail))
        }

        /// Runs a throwing block and records a failure if it throws.
        func noThrow(_ name: String, _ body: () throws -> Void) {
            do { try body(); checks += 1 }
            catch { fail(name, "threw \(error)") }
        }

        /// Records a failure if the block does NOT throw.
        func throwsError(_ name: String, _ body: () throws -> Void) {
            do { try body(); fail(name, "expected an error, none thrown") }
            catch { checks += 1 }
        }
    }

    struct Suite {
        let name: String
        let run: @MainActor (Context) throws -> Void
    }

    static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "selftest")

    static func runAll(_ suites: [Suite] = SelfTestRegistry.suites) -> Report {
        var report = Report()
        for suite in suites {
            let context = Context(suite: suite.name)
            do {
                try suite.run(context)
            } catch {
                context.fail("suite threw", "\(error)")
            }
            report.checks += context.checks
            report.failures.append(contentsOf: context.failures)
        }
        if report.passed {
            log.info("self-test: \(report.checks, privacy: .public) checks passed")
        } else {
            for failure in report.failures {
                log.error("self-test FAILED \(failure.suite, privacy: .public) / \(failure.name, privacy: .public): \(failure.detail, privacy: .public)")
            }
        }
        return report
    }

    /// DEBUG launch hook. Loud on failure, silent on success.
    static func runAtLaunchIfDebug() {
        #if DEBUG
        let report = runAll()
        assert(report.passed, "Self-tests failed: \(report.failures.map { "\($0.suite)/\($0.name)" })")
        #endif
    }
}
