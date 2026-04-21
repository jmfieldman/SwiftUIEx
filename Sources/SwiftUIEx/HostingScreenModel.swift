//
//  HostingScreenModel.swift
//  Copyright © 2026 Jason Fieldman.
//

import Observation
import UIKit

/// The controller-side model that backs a `HostingScreen`.
///
/// A `HostingScreenModel` owns the screen's logic: it holds references to
/// managers, services, and any other dependencies; it kicks off and
/// coordinates async work; and it performs UIKit-side actions such as
/// pushing the next view controller onto a navigation stack. It is the
/// single owner of the screen's lifetime-bound state.
///
/// The model vends a separate `ViewModel` — an `@Observable` reference type
/// of plain values and closures — that is shared with the SwiftUI
/// `HostedView`. The model writes into the view-model in response to its
/// own observations of upstream state (manager properties, async results,
/// etc.); the view reads from it. This split keeps the view-model trivially
/// constructible in `#Preview`s without pulling in the dependency graph
/// that the controller-side model needs.
///
/// `HostingScreen` sets `viewController` to itself after `super.init`
/// completes, giving the model a back-reference for navigation and
/// presentation work without requiring a strongly-typed reference to the
/// concrete `UIHostingController` subclass.
///
/// **Conformers MUST declare `viewController` as `weak`** to avoid a retain
/// cycle with the hosting controller. This is a runtime convention — Swift
/// protocols cannot enforce weak storage — but it must be followed:
///
///     public weak var viewController: UIViewController?
///
/// A typical conformance:
///
///     @MainActor
///     public final class MyScreenModel: HostingScreenModel {
///         public weak var viewController: UIViewController?
///         public let viewModel: MyViewModel
///
///         public init() {
///             self.viewModel = MyViewModel(onTap: { [weak self] in
///                 self?.handleTap()
///             })
///         }
///
///         private func handleTap() {
///             let next = NextScreen()
///             viewController?.navigationController?.pushViewController(
///                 next, animated: true
///             )
///         }
///     }
@MainActor
public protocol HostingScreenModel: AnyObject {
    /// The observable view-model shared with the `HostedView`. Constructed
    /// and owned by this model; the hosting controller passes it to the
    /// view's `init(viewModel:)` once.
    associatedtype ViewModel: Observable & AnyObject

    /// Weak back-reference to the hosting view controller, set by
    /// `HostingScreen` after `super.init`. Use it for navigation
    /// (`viewController?.navigationController?.pushViewController(...)`),
    /// presentation, dismissal, and similar UIKit work.
    ///
    /// **Must be declared `weak`** by conformers to avoid a retain cycle.
    var viewController: UIViewController? { get set }

    /// The view-model passed to the `HostedView`. Read once by
    /// `HostingScreen.init` and handed to the view.
    var viewModel: ViewModel { get }
}
