//
//  HostingScreen.swift
//  Copyright © 2026 Jason Fieldman.
//

import SwiftUI
import UIKit

/// A generic `UIHostingController` base class that wires a
/// `HostingScreenModel` to its `HostedView` and absorbs the boilerplate
/// every screen otherwise has to repeat.
///
/// Subclasses provide a `convenience` initializer that constructs the
/// concrete `HostingScreenModel` and forwards it to
/// `init(controllerModel:)`. Because the subclass adds no new designated
/// initializers, the superclass's designated initializers — including
/// `init?(coder:)` — are inherited automatically, so subclasses do not have
/// to re-declare the unavailable `init?(coder:)` boilerplate.
///
/// A typical subclass:
///
///     public final class MyScreen: HostingScreen<MyScreenModel, MyView> {
///         public convenience init() {
///             self.init(controllerModel: MyScreenModel())
///             navigationItem.title = "My Screen"
///         }
///     }
///
/// At init time the base class:
///
/// 1. Stores the model on `self.controllerModel`.
/// 2. Constructs the root view by calling `RootView(viewModel:
///    controllerModel.viewModel)`.
/// 3. Sets `controllerModel.viewController = self` so the model can drive
///    UIKit navigation without a typed reference back to the concrete
///    subclass.
///
/// This class deliberately does **not** override any `UIViewController`
/// lifecycle method. Subclasses (and apps) own their own appearance,
/// `viewDidLoad` / `viewWillAppear` configuration, etc.
@MainActor
open class HostingScreen<
    Model: HostingScreenModel,
    RootView: HostedView
>: UIHostingController<RootView> where RootView.ViewModel == Model.ViewModel {
    /// The model backing this screen. Exposed publicly so extensions on
    /// concrete subclasses can read state and dispatch through it.
    public let controllerModel: Model

    /// Designated initializer.
    ///
    /// - Parameter controllerModel: The fully-constructed model for this
    ///   screen. Its `viewModel` is read once and passed to the root view's
    ///   `init(viewModel:)`. Its `viewController` is then set to `self`.
    public init(controllerModel: Model) {
        self.controllerModel = controllerModel
        super.init(rootView: RootView(viewModel: controllerModel.viewModel))
        controllerModel.viewController = self
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
