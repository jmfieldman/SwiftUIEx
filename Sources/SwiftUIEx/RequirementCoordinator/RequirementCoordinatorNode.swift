//
//  RequirementCoordinatorNode.swift
//  Copyright © 2026 Jason Fieldman.
//

import UIKit

/// A single step in a `RequirementCoordinator` flow.
///
/// Each node pairs a reactive satisfaction predicate with a view-controller
/// factory. The coordinator shows the factory's view controller while
/// `isSatisfied()` returns `false`, and advances to the next unsatisfied
/// node as soon as the predicate flips to `true`.
///
/// The `isSatisfied` closure is intentionally a plain synchronous function,
/// not a Combine publisher or stream. The coordinator reads it inside
/// `withObservationTracking`, so any `@Observable` property the closure
/// touches — on any model it captures — will re-fire the satisfaction check
/// when it mutates.
///
/// Factories are called at most once each, the first time a node becomes
/// current, so already-satisfied nodes never materialize their view
/// controllers. This keeps expensive screen construction lazy.
public struct RequirementCoordinatorNode {
    /// A human-readable identifier, used only for debugging / logging.
    /// Defaults to `"\(#fileID):\(#line)"` of the node's construction site.
    public let id: String

    /// Main-actor predicate reporting whether this node's requirement is
    /// currently satisfied. Read by the coordinator inside
    /// `withObservationTracking` to drive advancement.
    public let isSatisfied: @MainActor () -> Bool

    /// Main-actor factory for the view controller shown while this node is
    /// unsatisfied. Called at most once — the first time the node becomes
    /// current.
    public let makeViewController: @MainActor () -> UIViewController

    /// - Parameters:
    ///   - id: Optional override for the default `file:line` identifier.
    ///     Pass a descriptive string if the default isn't informative enough
    ///     in logs.
    ///   - isSatisfied: Main-actor predicate called under Observation
    ///     tracking to drive advancement.
    ///   - makeViewController: Main-actor factory for the node's view
    ///     controller; called once when the node becomes current.
    public init(
        id: String? = nil,
        isSatisfied: @escaping @MainActor () -> Bool,
        makeViewController: @escaping @MainActor () -> UIViewController,
        file: String = #fileID,
        line: Int = #line
    ) {
        self.id = id ?? "\(file):\(line)"
        self.isSatisfied = isSatisfied
        self.makeViewController = makeViewController
    }
}

public extension Array where Element == RequirementCoordinatorNode {
    /// `true` when every node's `isSatisfied()` returns `true` at this exact
    /// moment.
    ///
    /// This is a point-in-time check; it does **not** observe future
    /// changes. Use it at the call site to short-circuit before presenting
    /// any UI — e.g., skip creating and presenting a `UINavigationController`
    /// entirely when the requirements flow has nothing to show.
    @MainActor
    var areAllSatisfied: Bool {
        allSatisfy { $0.isSatisfied() }
    }
}
