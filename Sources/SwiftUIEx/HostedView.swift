//
//  HostedView.swift
//  Copyright © 2026 Jason Fieldman.
//

import Observation
import SwiftUI

/// A SwiftUI `View` that is constructed from a single observable view-model
/// reference and rendered inside a `HostingScreen`.
///
/// Conforming views expose exactly one initializer, `init(viewModel:)`, which
/// the `HostingScreen` calls during its own initialization. The view itself
/// stores the model however it likes — typically as a plain `let viewModel:
/// ViewModel`, since `@Observable` tracks property reads through any
/// reference, and SwiftUI re-renders the view's body when those reads change.
///
/// The associated `ViewModel` is constrained to be a reference type that
/// participates in the Observation framework (i.e. a class marked
/// `@Observable`). This is the contract the rest of the library relies on:
/// the view-model is created once, owned by a `HostingScreenModel`, and
/// shared by reference with the view; mutations on the model propagate to
/// the view through Observation rather than through SwiftUI value semantics.
///
/// A typical conformance:
///
///     @Observable @MainActor
///     public final class MyViewModel {
///         public var title: String = ""
///         public let onTap: () -> Void
///         public init(title: String = "", onTap: @escaping () -> Void = {}) {
///             self.title = title
///             self.onTap = onTap
///         }
///     }
///
///     public struct MyView: HostedView {
///         let viewModel: MyViewModel
///         public init(viewModel: MyViewModel) {
///             self.viewModel = viewModel
///         }
///         public var body: some View {
///             Button(viewModel.title, action: viewModel.onTap)
///         }
///     }
@MainActor
public protocol HostedView: View {
    /// The observable view-model this view renders. Must be a reference type
    /// (so it can be shared with the owning `HostingScreenModel`) and must
    /// participate in Observation (so SwiftUI re-renders on mutation).
    associatedtype ViewModel: Observable & AnyObject

    /// Construct the view from its view-model. Called by `HostingScreen`
    /// during initialization with the model vended by the owning
    /// `HostingScreenModel`.
    init(viewModel: ViewModel)
}
