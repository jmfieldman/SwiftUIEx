//
//  RequirementCoordinatorTests.swift
//  Copyright © 2026 Jason Fieldman.
//
//  Exercises RequirementCoordinator end-to-end: prime/run ergonomics,
//  empty-vs-populated nav push strategy, reactive advancement driven by
//  @Observable mutations, ordering, cancellation, the stale-primed race,
//  and chained coordinators sharing a single nav.
//

import Observation
import UIKit
import XCTest

@testable import SwiftUIEx

/// A trivially-constructible `@Observable` gate used to drive node
/// satisfaction from the tests. Flipping `isOpen` is what advances the
/// coordinator.
@Observable
@MainActor
private final class Gate {
    var isOpen: Bool
    init(_ isOpen: Bool = false) { self.isOpen = isOpen }
}

/// A multi-property `@Observable` used by the arbitrary-property test.
/// Declared at file scope because `@Observable` is an attached extension
/// macro and cannot be applied to a type declared inside a function body.
@Observable
@MainActor
private final class Profile {
    var name: String = ""
    var age: Int = 0
}

@MainActor
final class RequirementCoordinatorTests: XCTestCase {
    // MARK: - prime

    func testPrimeReturnsFalseWhenAllSatisfied() {
        let gate = Gate(true)
        let coord = RequirementCoordinator(
            nodes: [
                .init(
                    isSatisfied: { gate.isOpen },
                    makeViewController: {
                        XCTFail("factory should not run when all satisfied")
                        return UIViewController()
                    }
                )
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertFalse(coord.prime(nav, animated: true))
        XCTAssertTrue(nav.viewControllers.isEmpty)
    }

    func testPrimeReturnsFalseForEmptyNodeArray() {
        let coord = RequirementCoordinator(nodes: [], advanceDelay: .zero)
        let nav = UINavigationController()
        XCTAssertFalse(coord.prime(nav, animated: false))
        XCTAssertTrue(nav.viewControllers.isEmpty)
    }

    func testPrimeSkipsAlreadySatisfiedNodesAndPlacesFirstUnsatisfied() {
        let gateA = Gate(true)
        let gateB = Gate(false)
        let vcB = UIViewController()

        let coord = RequirementCoordinator(
            nodes: [
                .init(
                    isSatisfied: { gateA.isOpen },
                    makeViewController: {
                        XCTFail("already-satisfied node's factory must not run")
                        return UIViewController()
                    }
                ),
                .init(isSatisfied: { gateB.isOpen }, makeViewController: { vcB }),
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        XCTAssertEqual(nav.viewControllers.count, 1)
        XCTAssertTrue(nav.viewControllers.first === vcB)
    }

    func testPrimeOnEmptyNavUsesSetViewControllersRegardlessOfAnimated() {
        // Empty nav: `animated:` is ignored and the VC is set directly.
        // The observable result is identical either way — a single VC on
        // the stack — so we exercise both animated: values to confirm no
        // behavioural difference.
        for animated in [false, true] {
            let gate = Gate(false)
            let vc = UIViewController()
            let coord = RequirementCoordinator(
                nodes: [.init(isSatisfied: { gate.isOpen }, makeViewController: { vc })],
                advanceDelay: .zero
            )
            let nav = UINavigationController()
            XCTAssertTrue(coord.prime(nav, animated: animated))
            XCTAssertEqual(nav.viewControllers.count, 1, "animated=\(animated)")
            XCTAssertTrue(nav.viewControllers.first === vc, "animated=\(animated)")
        }
    }

    func testPrimeOnPopulatedNavPushesOntoExistingStack() {
        // Simulate attaching the flow onto a nav that already has content
        // (the core enabler for the chained-coordinator pattern).
        let preexisting = UIViewController()
        let nav = UINavigationController(rootViewController: preexisting)

        let gate = Gate(false)
        let vc = UIViewController()
        let coord = RequirementCoordinator(
            nodes: [.init(isSatisfied: { gate.isOpen }, makeViewController: { vc })],
            advanceDelay: .zero
        )

        XCTAssertTrue(coord.prime(nav, animated: true))
        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.first === preexisting)
        XCTAssertTrue(nav.viewControllers.last === vc)
    }

    // MARK: - run

    func testRunWithoutPrimeIsNoOp() async throws {
        let gate = Gate(false)
        let coord = RequirementCoordinator(
            nodes: [
                .init(isSatisfied: { gate.isOpen }, makeViewController: { UIViewController() })
            ],
            advanceDelay: .zero
        )

        // Never primed — run returns immediately without hanging.
        try await coord.run()
    }

    func testRunAfterPrimeReturnedFalseIsNoOp() async throws {
        let gate = Gate(true)  // already satisfied
        let coord = RequirementCoordinator(
            nodes: [
                .init(isSatisfied: { gate.isOpen }, makeViewController: { UIViewController() })
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertFalse(coord.prime(nav, animated: true))
        try await coord.run()  // no work to do; returns cleanly
    }

    func testSingleNodeAdvancesOnSatisfaction() async throws {
        let gate = Gate(false)
        let vc = UIViewController()
        let coord = RequirementCoordinator(
            nodes: [.init(isSatisfied: { gate.isOpen }, makeViewController: { vc })],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        XCTAssertTrue(nav.viewControllers.first === vc)

        let task = Task { try await coord.run() }

        // Give the coordinator a beat to suspend. If it were going to re-push
        // the primed VC, that would show up here.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(nav.viewControllers.count, 1)

        gate.isOpen = true
        try await task.value
        XCTAssertEqual(nav.viewControllers.count, 1)
    }

    func testMultipleNodesAdvanceInOrder() async throws {
        let gateA = Gate(false)
        let gateB = Gate(false)
        let vcA = UIViewController()
        let vcB = UIViewController()

        let coord = RequirementCoordinator(
            nodes: [
                .init(isSatisfied: { gateA.isOpen }, makeViewController: { vcA }),
                .init(isSatisfied: { gateB.isOpen }, makeViewController: { vcB }),
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        XCTAssertTrue(nav.viewControllers.first === vcA)

        let task = Task { try await coord.run() }

        gateA.isOpen = true
        try await waitUntil { nav.viewControllers.count == 2 }
        XCTAssertTrue(nav.viewControllers.last === vcB)

        gateB.isOpen = true
        try await task.value
        XCTAssertEqual(nav.viewControllers.count, 2)
    }

    func testFactoryIsCalledLazilyOnlyWhenNodeBecomesCurrent() async throws {
        let gateA = Gate(false)
        let gateB = Gate(false)
        var aFactoryCalls = 0
        var bFactoryCalls = 0

        let coord = RequirementCoordinator(
            nodes: [
                .init(
                    isSatisfied: { gateA.isOpen },
                    makeViewController: {
                        aFactoryCalls += 1
                        return UIViewController()
                    }
                ),
                .init(
                    isSatisfied: { gateB.isOpen },
                    makeViewController: {
                        bFactoryCalls += 1
                        return UIViewController()
                    }
                ),
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        XCTAssertEqual(aFactoryCalls, 1)
        XCTAssertEqual(bFactoryCalls, 0, "second node's factory must not be called yet")

        let task = Task { try await coord.run() }
        gateA.isOpen = true
        try await waitUntil { nav.viewControllers.count == 2 }
        XCTAssertEqual(aFactoryCalls, 1, "primed VC must not be rebuilt")
        XCTAssertEqual(bFactoryCalls, 1)

        gateB.isOpen = true
        try await task.value
    }

    func testSatisfactionObservesArbitraryObservableProperty() async throws {
        // The predicate reads properties on an @Observable that isn't the
        // node's own — proves Observation tracking follows captures, not
        // anything specific to the node struct, and that re-arming picks
        // up subsequent mutations after a non-satisfying change.
        let profile = Profile()
        let vc = UIViewController()
        let coord = RequirementCoordinator(
            nodes: [
                .init(
                    isSatisfied: { !profile.name.isEmpty && profile.age >= 18 },
                    makeViewController: { vc }
                )
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        let task = Task { try await coord.run() }

        // Mutate one property at a time — coordinator must re-arm after
        // each non-satisfying change and still pick up the next one.
        profile.name = "Ada"
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(task.isCancelled)

        profile.age = 21
        try await task.value
    }

    // MARK: - Stale-primed race

    func testRunAfterPrimeHandlesStalePrime() async throws {
        // Race: prime the first node's VC, then satisfy it before run()
        // starts. The coordinator must still advance correctly — pushing
        // the next unsatisfied node animated (nav is visible).
        let gateA = Gate(false)
        let gateB = Gate(false)
        var aFactoryCalls = 0
        let vcB = UIViewController()

        let coord = RequirementCoordinator(
            nodes: [
                .init(
                    isSatisfied: { gateA.isOpen },
                    makeViewController: {
                        aFactoryCalls += 1
                        return UIViewController()
                    }
                ),
                .init(isSatisfied: { gateB.isOpen }, makeViewController: { vcB }),
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        let primedVC = nav.viewControllers.first
        XCTAssertEqual(aFactoryCalls, 1)

        // Satisfy node A *before* run() starts — the prime is now stale.
        gateA.isOpen = true

        let task = Task { try await coord.run() }
        try await waitUntil { nav.viewControllers.count == 2 }
        XCTAssertTrue(nav.viewControllers.first === primedVC, "stale primed VC stays at root")
        XCTAssertTrue(nav.viewControllers.last === vcB, "next unsatisfied VC is pushed on top")
        XCTAssertEqual(aFactoryCalls, 1, "node A's factory must not be called again")

        gateB.isOpen = true
        try await task.value
    }

    // MARK: - Chained coordinators

    func testChainedCoordinatorsSharingSameNav() async throws {
        // The headline use case: two independent coordinators flow through
        // the same UINavigationController, with the second one pushing its
        // first screen animated onto the stack the first one left behind.
        let gateA = Gate(false)
        let gateB = Gate(false)
        let vcA = UIViewController()
        let vcB = UIViewController()

        let stage1 = RequirementCoordinator(
            nodes: [.init(isSatisfied: { gateA.isOpen }, makeViewController: { vcA })],
            advanceDelay: .zero
        )
        let stage2 = RequirementCoordinator(
            nodes: [.init(isSatisfied: { gateB.isOpen }, makeViewController: { vcB })],
            advanceDelay: .zero
        )

        let nav = UINavigationController()

        // Stage 1: empty nav → set as root, no animation.
        XCTAssertTrue(stage1.prime(nav, animated: false))
        XCTAssertEqual(nav.viewControllers, [vcA])

        let task1 = Task { try await stage1.run() }
        gateA.isOpen = true
        try await task1.value

        // Stage 2: populated nav (vcA still on top) → animated push onto it.
        XCTAssertTrue(stage2.prime(nav, animated: true))
        XCTAssertEqual(nav.viewControllers, [vcA, vcB])

        let task2 = Task { try await stage2.run() }
        gateB.isOpen = true
        try await task2.value

        // Both stages' VCs are still on the stack — caller decides dismiss.
        XCTAssertEqual(nav.viewControllers, [vcA, vcB])
    }

    // MARK: - Cancellation

    func testCancellationThrowsCancellationError() async throws {
        let gate = Gate(false)
        let coord = RequirementCoordinator(
            nodes: [
                .init(isSatisfied: { gate.isOpen }, makeViewController: { UIViewController() })
            ],
            advanceDelay: .zero
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        let task = Task { try await coord.run() }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunThrowsCancellationIfNavIsReleasedBeforeNextPush() async throws {
        // Weak nav ref: if the caller drops the nav without cancelling the
        // task, run() surfaces the disappearance as CancellationError the
        // next time it needs to push.
        let gateA = Gate(false)
        let gateB = Gate(false)
        let coord = RequirementCoordinator(
            nodes: [
                .init(isSatisfied: { gateA.isOpen }, makeViewController: { UIViewController() }),
                .init(isSatisfied: { gateB.isOpen }, makeViewController: { UIViewController() }),
            ],
            advanceDelay: .zero
        )

        // Prime in a narrow scope so the only strong ref to the nav
        // expires when the scope ends.
        do {
            let nav = UINavigationController()
            XCTAssertTrue(coord.prime(nav, animated: false))
        }
        // Nav is now deallocated (its last strong ref left scope).

        let task = Task { try await coord.run() }

        // Flip node A so run() tries to advance and push node B — but
        // the nav is gone, so it must throw.
        gateA.isOpen = true

        do {
            try await task.value
            XCTFail("expected CancellationError after nav was released")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - areAllSatisfied extension

    func testAreAllSatisfiedHelper() {
        let a = Gate(true)
        let b = Gate(true)
        let nodes: [RequirementCoordinatorNode] = [
            .init(isSatisfied: { a.isOpen }, makeViewController: { UIViewController() }),
            .init(isSatisfied: { b.isOpen }, makeViewController: { UIViewController() }),
        ]
        XCTAssertTrue(nodes.areAllSatisfied)

        b.isOpen = false
        XCTAssertFalse(nodes.areAllSatisfied)

        XCTAssertTrue(([] as [RequirementCoordinatorNode]).areAllSatisfied)
    }

    // MARK: - advanceDelay

    func testAdvanceDelayDelaysCompletion() async throws {
        let gate = Gate(false)
        let coord = RequirementCoordinator(
            nodes: [
                .init(isSatisfied: { gate.isOpen }, makeViewController: { UIViewController() })
            ],
            advanceDelay: .milliseconds(150)
        )

        let nav = UINavigationController()
        XCTAssertTrue(coord.prime(nav, animated: false))
        let task = Task { try await coord.run() }

        try await Task.sleep(for: .milliseconds(20))
        let flipTime = ContinuousClock.now
        gate.isOpen = true
        try await task.value
        let elapsed = ContinuousClock.now - flipTime

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(140))
    }

    // MARK: - Helpers

    /// Poll `condition` on the main actor until it becomes `true`, or fail
    /// the test if `timeout` elapses first. Used instead of `Task.yield()`
    /// because the coordinator's reaction to a satisfaction flip involves
    /// more than one actor hop (observation onChange → stream yield →
    /// consumer resume → advanceDelay → next push), and a single yield
    /// isn't enough to reliably drive all of them.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out after \(timeout)", file: file, line: line)
    }
}
