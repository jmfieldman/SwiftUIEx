//
//  RequirementCoordinator.swift
//  Copyright © 2026 Jason Fieldman.
//

import Observation
import UIKit

/// Advances a user through a list of `RequirementCoordinatorNode`s on a
/// `UINavigationController`, pushing each node's view controller and moving
/// on as each node's reactive `isSatisfied` predicate flips to `true`.
///
/// ## Shape
///
/// - **Observable-native.** Satisfaction is a plain synchronous closure,
///   read inside `withObservationTracking`. Any mutation on any `@Observable`
///   property the closure reads re-fires the check. No Combine.
/// - **Unopinionated start/stop.** The coordinator attaches to a navigation
///   controller the caller created. On completion it returns — it does
///   **not** present, pop, or dismiss anything. The caller decides what
///   happens before the flow (how the nav controller is presented) and
///   after it (dismiss, pop to some anchor, push a result screen, whatever).
/// - **Chain-friendly.** Because `prime(_:animated:)` decides between
///   `setViewControllers` (empty nav) and `pushViewController` (populated
///   nav) automatically, a completed coordinator's last screen can be the
///   root for the next coordinator without any special handoff logic.
/// - **Main-actor only.** Every surface is `@MainActor`; satisfaction
///   predicates and view-controller factories run on the main actor.
///
/// ## Usage
///
/// Three-step sequence — prime, present, run — ensures the first node is on
/// the navigation controller *before* presentation, so the nav animates in
/// with real content (no blank-nav flash):
///
///     let coord = RequirementCoordinator(nodes: [
///         .init(isSatisfied: { auth.isLoggedIn },
///               makeViewController: { LoginScreen(auth: auth) }),
///         .init(isSatisfied: { profile.isComplete },
///               makeViewController: { ProfileCompletionScreen(profile: profile) }),
///     ])
///
///     let nav = UINavigationController()
///
///     // Prime does three things in one call:
///     //   1. Reports whether any node is unsatisfied (the guard).
///     //   2. Attaches the nav controller to the coordinator.
///     //   3. Places the first unsatisfied node's VC on the nav, choosing
///     //      between `setViewControllers` (empty nav, unanimated) and
///     //      `pushViewController` (populated nav, honors `animated:`).
///     guard coord.prime(nav, animated: false) else {
///         // everything already satisfied — no flow to run
///         return
///     }
///
///     present(nav, animated: true)
///
///     Task {
///         do {
///             try await coord.run()
///             // All requirements satisfied — caller decides what next.
///             nav.dismiss(animated: true)
///         } catch {
///             // Cancelled — caller decides what next.
///         }
///     }
///
/// ## Chaining coordinators on a shared nav
///
/// Because `prime` decides the push strategy from the nav's current state,
/// a second coordinator can attach to the same nav once the first has
/// completed, animating its first screen onto the stack left by the
/// previous flow:
///
///     guard authCoord.prime(nav, animated: false) else { /* already authed */ }
///     present(nav, animated: true)
///     try await authCoord.run()
///
///     guard profileCoord.prime(nav, animated: true) else { /* already complete */
///         nav.dismiss(animated: true)
///         return
///     }
///     try await profileCoord.run()
///
///     nav.dismiss(animated: true)
///
/// Each coordinator is one-shot — calling `prime` twice on the same
/// coordinator is a programming error and trips a precondition. Use a
/// fresh coordinator instance per stage.
@MainActor
public final class RequirementCoordinator {
    /// The nodes this coordinator advances through, in order.
    public let nodes: [RequirementCoordinatorNode]

    /// Pause inserted after a node becomes satisfied, before either pushing
    /// the next node or returning from `run()`. Gives the user a beat to
    /// see the success state of the current screen before the navigation
    /// moves on.
    public let advanceDelay: Duration

    /// Weak reference to the navigation controller passed to `prime`.
    /// Weak so that the caller releasing the nav (e.g. on dismissal
    /// without cancelling the Task) surfaces as a cancellation in `run()`
    /// rather than pinning the nav alive until satisfaction.
    private weak var primedNav: UINavigationController?

    /// ID of the node whose view controller was placed on the nav during
    /// `prime`. Consumed by `run()`'s first iteration so it knows whether
    /// to skip the first push (primed match) or push the current
    /// first-unsatisfied node animated (stale primed state).
    private var primedNodeID: String?

    /// Set to `true` on the first call to `prime`, whether or not it
    /// returned `true`. Used solely to precondition-fail on a second call.
    private var hasPrimed: Bool = false

    /// - Parameters:
    ///   - nodes: The nodes to advance through, in order. Nodes whose
    ///     `isSatisfied()` already returns `true` at the moment they
    ///     become current are skipped without ever calling
    ///     `makeViewController`.
    ///   - advanceDelay: Pause after each node becomes satisfied. Defaults
    ///     to `350 ms` — short enough to feel responsive, long enough for
    ///     the user to register the success state. Pass `.zero` to advance
    ///     immediately.
    public init(
        nodes: [RequirementCoordinatorNode],
        advanceDelay: Duration = .milliseconds(350)
    ) {
        self.nodes = nodes
        self.advanceDelay = advanceDelay
    }

    /// Attaches a navigation controller to this coordinator and places the
    /// first unsatisfied node's view controller on it, in one call.
    ///
    /// Returns `true` when there is a flow to run (at least one node is
    /// unsatisfied). Returns `false` when every node is already satisfied;
    /// in that case the navigation controller is left untouched and the
    /// caller can skip presenting it entirely.
    ///
    /// ### Push strategy
    ///
    /// - **Empty nav (`viewControllers.isEmpty`):** the coordinator calls
    ///   `setViewControllers([vc], animated: false)`. The `animated:`
    ///   argument is ignored — there is no meaningful source frame to
    ///   animate from on an empty stack.
    /// - **Populated nav:** the coordinator calls
    ///   `pushViewController(vc, animated: animated)`, honoring the
    ///   caller's choice. This is the chaining path: a previous
    ///   coordinator's final screen sits at the top of the stack, and the
    ///   new coordinator's first screen pushes on top with the caller's
    ///   chosen animation.
    ///
    /// ### Lifetime and invariants
    ///
    /// - The coordinator holds the navigation controller **weakly**. If
    ///   the caller releases the nav before `run()` is called (or during
    ///   it), `run()` surfaces the disappearance as `CancellationError`.
    /// - Must be called **at most once** per coordinator. A second call
    ///   trips a `precondition`. Create a fresh coordinator for each stage
    ///   of a chained flow.
    ///
    /// - Parameters:
    ///   - navigationController: The navigation controller to attach to
    ///     and place the first node's VC onto.
    ///   - animated: Whether to animate the push onto a non-empty nav.
    ///     Ignored when the nav is empty.
    /// - Returns: `true` if a view controller was placed on the nav and
    ///   there is a flow to run; `false` if every node was already
    ///   satisfied and nothing was done.
    public func prime(
        _ navigationController: UINavigationController,
        animated: Bool
    ) -> Bool {
        precondition(
            !hasPrimed,
            "RequirementCoordinator.prime(_:animated:) was called twice on the same coordinator. Instantiate a fresh RequirementCoordinator for each stage of a chained flow."
        )
        hasPrimed = true

        guard let node = firstUnsatisfiedNode() else { return false }

        primedNav = navigationController
        primedNodeID = node.id

        let vc = node.makeViewController()
        if navigationController.viewControllers.isEmpty {
            navigationController.setViewControllers([vc], animated: false)
        } else {
            navigationController.pushViewController(vc, animated: animated)
        }

        return true
    }

    /// Runs the flow against the navigation controller attached in `prime`.
    ///
    /// Observes the current node's `isSatisfied` predicate via
    /// `withObservationTracking`. When it flips to `true`, pauses
    /// `advanceDelay` so the user sees the success state, then pushes the
    /// next unsatisfied node (animated). Returns when every node is
    /// satisfied.
    ///
    /// ### Three entry scenarios
    ///
    /// 1. **Not primed, or prime returned `false`.** Silent no-op: `run()`
    ///    returns immediately. The canonical `guard coord.prime(...) else
    ///    return` pattern should make this branch unreachable, but if the
    ///    caller ignores the guard and calls `run()` anyway, there's
    ///    nothing to do and no error worth raising.
    /// 2. **Primed and still fresh.** The primed node is still the first
    ///    unsatisfied one. `run()` skips the first push (that VC is on
    ///    the nav already) and begins observing it.
    /// 3. **Primed but stale** (primed node was satisfied between `prime`
    ///    and `run`). `run()` detects the mismatch and pushes the current
    ///    first-unsatisfied node *animated* — the nav is visible by then,
    ///    so an animated push is the right visual. The stale primed VC
    ///    stays wherever it was in the stack; the caller can pop past it
    ///    when dismissing if needed.
    ///
    /// If the navigation controller is released before `run()` needs to
    /// push on it, `run()` throws `CancellationError`. Task cancellation
    /// also throws `CancellationError`.
    public func run() async throws {
        guard let primedID = primedNodeID else { return }
        primedNodeID = nil

        var isFirstIteration = true
        while let node = firstUnsatisfiedNode() {
            let isPrimedMatch = isFirstIteration && node.id == primedID
            if !isPrimedMatch {
                // Either a subsequent iteration (push onto a visible nav,
                // animated) or a stale-primed first iteration (nav is
                // visible because the caller primed+presented, so animate
                // too). Either way, animated.
                guard let nav = primedNav else { throw CancellationError() }
                nav.pushViewController(node.makeViewController(), animated: true)
            }
            isFirstIteration = false

            try await waitUntilSatisfied(node)

            if advanceDelay > .zero {
                try await Task.sleep(for: advanceDelay)
            }
        }
    }

    private func firstUnsatisfiedNode() -> RequirementCoordinatorNode? {
        nodes.first { !$0.isSatisfied() }
    }

    /// Suspends until `node.isSatisfied()` returns `true`. Uses
    /// `withObservationTracking` to re-fire on every mutation of any
    /// `@Observable` property the predicate reads, and re-arms after each
    /// wakeup since `withObservationTracking` only fires its `onChange`
    /// once per registration.
    private func waitUntilSatisfied(_ node: RequirementCoordinatorNode) async throws {
        if node.isSatisfied() { return }

        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        @MainActor
        func arm() {
            withObservationTracking {
                _ = node.isSatisfied()
            } onChange: {
                continuation.yield()
            }
        }

        arm()

        for await _ in stream {
            try Task.checkCancellation()
            if node.isSatisfied() {
                continuation.finish()
                return
            }
            arm()
        }

        // Stream terminated without satisfaction — task was cancelled.
        throw CancellationError()
    }
}
