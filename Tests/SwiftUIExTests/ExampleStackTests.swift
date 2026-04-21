//
//  ExampleStackTests.swift
//  Copyright © 2026 Jason Fieldman.
//
//  A complete, end-to-end example stack — ViewModel + HostedView +
//  HostingScreenModel + HostingScreen subclass — wired together. The point
//  of this file is primarily to prove that the generic constraints and
//  protocol shape compose without friction. The runtime assertions are a
//  bonus that confirms the wiring actually does what the protocols claim.
//

import SwiftUI
import UIKit
import XCTest

@testable import SwiftUIEx

// MARK: - Example stack

/// An `@Observable` ViewModel of plain values and closures. Trivially
/// constructible — the kind of thing a `#Preview` can build with no
/// dependencies in scope.
///
/// `onTap` is a `var` so the controller-side model can wire it to a closure
/// that captures `[weak self]` *after* the model is fully initialized
/// (Swift's definite-init analysis forbids capturing `self`, even weakly,
/// before every stored property has been assigned).
@Observable
@MainActor
final class ExampleViewModel {
    var title: String
    var onTap: () -> Void

    init(title: String = "", onTap: @escaping () -> Void = {}) {
        self.title = title
        self.onTap = onTap
    }
}

/// A `HostedView` that renders the view-model. Storage is a plain `let` —
/// Observation tracks per-property reads, so SwiftUI re-renders when the
/// model mutates without needing `@State` / `@Bindable`.
struct ExampleView: HostedView {
    let viewModel: ExampleViewModel

    init(viewModel: ExampleViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Button(viewModel.title, action: viewModel.onTap)
    }
}

/// A `HostingScreenModel` written in the **two-step** style: construct the
/// `viewModel` first (so all stored properties are initialized), then assign
/// its callback closures, which can now safely capture `[weak self]` because
/// `self` is fully formed.
@MainActor
final class ExampleScreenModelTwoStep: HostingScreenModel {
    weak var viewController: UIViewController?
    let viewModel: ExampleViewModel

    private(set) var tapCount: Int = 0

    init(initialTitle: String) {
        self.viewModel = ExampleViewModel(title: initialTitle)
        // self is now fully initialized; safe to capture.
        self.viewModel.onTap = { [weak self] in
            self?.tapCount += 1
        }
    }
}

/// A `HostingScreenModel` written in the **lazy** style: store the init
/// parameters as ivars, then declare `viewModel` as a `lazy var` whose
/// initializer constructs the `ExampleViewModel` with all callbacks already
/// wired in. Because lazy initializers run after `init` completes, the
/// `[weak self]` capture inside the closure is always valid.
@MainActor
final class ExampleScreenModelLazy: HostingScreenModel {
    weak var viewController: UIViewController?
    private let initialTitle: String
    private(set) lazy var viewModel: ExampleViewModel = .init(
        title: initialTitle,
        onTap: { [weak self] in
            self?.tapCount += 1
        },
    )

    private(set) var tapCount: Int = 0

    init(initialTitle: String) {
        self.initialTitle = initialTitle
    }
}

/// A concrete `HostingScreen` subclass over the two-step model. The
/// convenience init constructs the model and forwards to the base's
/// designated init; UIKit configuration (e.g. `navigationItem.title`) lands
/// after.
final class ExampleScreen: HostingScreen<ExampleScreenModelTwoStep, ExampleView> {
    convenience init(initialTitle: String) {
        self.init(controllerModel: ExampleScreenModelTwoStep(initialTitle: initialTitle))
        navigationItem.title = initialTitle
    }
}

// MARK: - Tests

@MainActor
final class ExampleStackTests: XCTestCase {
    func testScreenWiresViewControllerAndViewModel() {
        let screen = ExampleScreen(initialTitle: "Hello")

        // The base class set `viewController` to itself.
        XCTAssertTrue(screen.controllerModel.viewController === screen)

        // The view-model passed to the root view is the same instance the
        // controller-model vends.
        XCTAssertTrue(screen.controllerModel.viewModel === screen.rootView.viewModel)

        // The closure plumbing routes view → view-model → controller-model.
        XCTAssertEqual(screen.controllerModel.tapCount, 0)
        screen.controllerModel.viewModel.onTap()
        XCTAssertEqual(screen.controllerModel.tapCount, 1)

        // Mutations on the @Observable view-model are visible through the
        // root view's reference (it's the same object).
        screen.controllerModel.viewModel.title = "Updated"
        XCTAssertEqual(screen.rootView.viewModel.title, "Updated")
    }

    func testLazyVariantComposesAndUsedDirectlyWithoutSubclass() {
        // The base class is `open` and fully usable on its own — subclassing
        // is a convenience, not a requirement. This test also doubles as
        // proof that the lazy-`viewModel` shape composes with `HostingScreen`.
        let model = ExampleScreenModelLazy(initialTitle: "Lazy")
        let screen = HostingScreen<ExampleScreenModelLazy, ExampleView>(controllerModel: model)

        XCTAssertTrue(model.viewController === screen)
        XCTAssertTrue(model.viewModel === screen.rootView.viewModel)

        // Closure routing works in the lazy shape too.
        XCTAssertEqual(model.tapCount, 0)
        model.viewModel.onTap()
        XCTAssertEqual(model.tapCount, 1)
    }

    func testViewControllerReferenceIsWeak() {
        // Sanity-check that the convention holds: when the screen goes away,
        // the model's back-reference clears (proving it was stored weakly,
        // and that there is no retain cycle from the screen → model →
        // viewController → screen).
        let model = ExampleScreenModelTwoStep(initialTitle: "Weak")
        do {
            let screen = HostingScreen<ExampleScreenModelTwoStep, ExampleView>(controllerModel: model)
            XCTAssertNotNil(model.viewController)
            _ = screen
        }
        XCTAssertNil(model.viewController)
    }
}
