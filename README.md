# SwiftUIEx

SwiftUIEx is a small library for embedding SwiftUI screens inside a **UIKit navigation stack** without writing the same `UIHostingController` boilerplate on every screen. It commits to the **`@Observable`** model: no Combine, no CombineEx, no `@State`-per-property bridging — just a shared observable view-model handed from a controller-side coordinator down to the SwiftUI view.

The library is intentionally tiny — three screen-plumbing types plus one narrow coordinator primitive — and stops there. It is not a general navigation framework, it is not opinionated about how you choose to push, present, or dismiss screens, and it is not a replacement for SwiftUI's own state primitives. It is the thin seam that makes "SwiftUI screen, UIKit nav" a one-line subclass instead of thirty lines of repeated scaffolding, plus a single `RequirementCoordinator` that captures one specific reactive pattern that composes especially cleanly into Observable.

## Why this exists

If you ship an iOS app whose navigation lives in `UINavigationController` but whose screens are written in SwiftUI, every screen ends up looking the same:

- A `UIHostingController` subclass that owns a model, calls `super.init(rootView:)` with the right wrapping, sets the model's back-reference to itself, and re-declares the unavailable `init?(coder:)`.
- A controller-side model that owns dependencies (managers, services, navigation), observes upstream state, and dispatches actions.
- A SwiftUI view that consumes a slice of state and fires actions back up.

Pulled apart, none of these pieces is hard. Bundled together, every screen re-states 25–35 lines of glue, and the resulting wiring rots in subtly different ways across screens.

SwiftUIEx absorbs the glue into a single generic base class and two protocols. What is left is exactly the per-screen content: a model that owns the deps, an `@Observable` view-model that the view reads, and a one-line subclass.

It deliberately stays out of the parts that the Observation framework already does well — view re-rendering on property reads, lazy dependency tracking, identity through reference — and stays out of the parts that the SwiftAsyncEx companion library covers (observation re-arming, task lifetime).

## The pattern

A screen is three pieces:

1. **`ViewModel`** — an `@Observable` reference type of plain `var`s and closures. It is the surface the SwiftUI view reads from and writes back through. It must be trivially constructible — `#Preview { MyView(viewModel: MyViewModel(...)) }` should compile with no dependency-injection harness in scope.

2. **`HostingScreenModel`** — the controller-side model. It owns managers, services, and navigation; it constructs the view-model in its `init`, wires the view-model's callback closures back into itself, and uses a weak `viewController` reference to drive UIKit navigation.

3. **`HostingScreen`** — a generic `UIHostingController` subclass. Constructed with a `HostingScreenModel`, it builds the `HostedView` from `model.viewModel`, sets `model.viewController = self`, and inherits `init?(coder:)` so subclasses do not have to re-declare it.

This split is deliberate. Merging the controller-side model and the view-model into a single class would force the view to construct the full dependency graph in `#Preview`s, which is the friction point that motivated the split in the first place. Keeping the view-model as a thin "data and closures" object preserves the cheapest-possible preview surface.

## Contents

### `HostedView`

A SwiftUI `View` constructed from a single observable view-model reference.

```swift
@MainActor
public protocol HostedView: View {
    associatedtype ViewModel: Observable & AnyObject
    init(viewModel: ViewModel)
}
```

The associated `ViewModel` is constrained to be a reference type marked `@Observable`. The view itself stores the model however it likes — typically as a plain `let viewModel: ViewModel`, since `@Observable` tracks property reads through any reference and SwiftUI re-renders on mutation. There is no need for `@State` (the model is owned by the controller, not the view) or `@Bindable` (the recommended idiom is read-observable-state, call-functions-on-changes — no two-way bindings).

### `HostingScreenModel`

The controller-side model that owns the screen's dependencies, vends the view-model, and receives a weak back-reference to the hosting view controller.

```swift
@MainActor
public protocol HostingScreenModel: AnyObject {
    associatedtype ViewModel: Observable & AnyObject
    var viewController: UIViewController? { get set }
    var viewModel: ViewModel { get }
}
```

`viewController` is typed as `UIViewController?` rather than the concrete `HostingScreen` subclass — every realistic use is `viewController?.navigationController?.pushViewController(...)` or `present(_:animated:)` / `dismiss(animated:)`, all of which are defined on `UIViewController` itself. Avoiding an associatedtype for the concrete subclass keeps the generics ergonomic.

**Conformers must declare `viewController` as `weak`.** Swift protocols cannot enforce weak storage, so this is a runtime convention — but every implementation should follow it to avoid a retain cycle with the hosting controller.

### `HostingScreen<Model, RootView>`

A generic `UIHostingController` subclass that wires the model to the view and absorbs the boilerplate every screen otherwise has to repeat.

```swift
@MainActor
open class HostingScreen<
    Model: HostingScreenModel,
    RootView: HostedView
>: UIHostingController<RootView> where RootView.ViewModel == Model.ViewModel {
    public let controllerModel: Model
    public init(controllerModel: Model) { ... }
}
```

At init time, the base class:

1. Stores the model on `self.controllerModel`.
2. Constructs the root view by calling `RootView(viewModel: controllerModel.viewModel)`.
3. Sets `controllerModel.viewController = self` so the model can drive UIKit navigation without a typed reference back to the concrete subclass.

The base class deliberately does not override any `UIViewController` lifecycle method. Subclasses (and apps) own their own `viewDidLoad` / `viewWillAppear` configuration, navigation-bar appearance, etc.

The base class is `open`, so subclassing is the typical entry point — but `HostingScreen<Model, RootView>(controllerModel: ...)` is also fully usable directly when the subclass would add nothing beyond constructing the model.

## Putting it together

A complete screen has four parts: a `ViewModel`, a `HostedView`, a `HostingScreenModel`, and a `HostingScreen` subclass. The first two and the last are uncontroversial — they look the same regardless of which `HostingScreenModel` style you pick.

```swift
import SwiftUIEx
import SwiftUI
import UIKit

// 1. ViewModel: @Observable, plain values and closures, preview-friendly.
@Observable
@MainActor
public final class BookNoteListViewModel {
    public var book: Book
    public var notes: [Note]
    public var selectNote: (Note) -> Void

    public init(
        book: Book,
        notes: [Note] = [],
        selectNote: @escaping (Note) -> Void = { _ in },
    ) {
        self.book = book
        self.notes = notes
        self.selectNote = selectNote
    }
}

// 2. HostedView: reads from the ViewModel, fires its closures.
public struct BookNoteListView: HostedView {
    let viewModel: BookNoteListViewModel

    public init(viewModel: BookNoteListViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List(viewModel.notes) { note in
            Button(note.title) { viewModel.selectNote(note) }
        }
        .navigationTitle(viewModel.book.title)
    }
}

#Preview {
    BookNoteListView(viewModel: BookNoteListViewModel(
        book: .init(title: "The Sample", author: "A. N. Author"),
        notes: [.init(title: "Chapter 1 thoughts"), .init(title: "Chapter 2 thoughts")],
    ))
}

// 4. HostingScreen subclass: one-line wiring, plus any UIKit configuration.
public final class BookNoteListScreen:
    HostingScreen<BookNoteListScreenModel, BookNoteListView>
{
    public convenience init(book: Book, libraryManager: LibraryManager) {
        self.init(controllerModel: BookNoteListScreenModel(
            book: book,
            libraryManager: libraryManager,
        ))
        navigationItem.title = book.title
    }
}
```

What does **not** appear in the screen:

- An `init?(coder:)` declaration (inherited from the base).
- A `controllerModel.viewController = self` line (the base sets it).
- A `super.init(rootView:)` call with hand-wrapped state bindings.
- Any `@State` on the view for properties owned by the model.
- Any framework-specific stream wrappers — just `var` properties on an `@Observable` class.

What's left is the **`HostingScreenModel`** itself, where there are two reasonable shapes to pick from. They are interchangeable from the screen's perspective and from the ViewModel's perspective; the difference is purely how the model's `init` is laid out.

### `HostingScreenModel` style A: two-step

Construct the `viewModel` first, then assign its callback closures. Because all stored properties are set before the closure is created, `[weak self]` captures are valid.

```swift
@MainActor
public final class BookNoteListScreenModel: HostingScreenModel {
    public weak var viewController: UIViewController?
    public let viewModel: BookNoteListViewModel
    private let libraryManager: LibraryManager

    public init(book: Book, libraryManager: LibraryManager) {
        self.libraryManager = libraryManager
        self.viewModel = BookNoteListViewModel(book: book)

        // self is fully initialized here — safe to capture weakly.
        self.viewModel.selectNote = { [weak self] note in
            self?.handleSelect(note)
        }

        // Stream upstream state into the ViewModel using SwiftAsyncEx helpers.
        Task.onChange(of: { libraryManager.notes(for: book.id) }) { [weak self] notes in
            self?.viewModel.notes = notes
        }.bind(to: self)
    }

    private func handleSelect(_ note: Note) {
        let next = SingleNoteScreen(noteId: note.id, libraryManager: libraryManager)
        viewController?.navigationController?.pushViewController(next, animated: true)
    }
}
```

This style requires the ViewModel's callback ivars to be **`var`** (they get assigned after construction).

### `HostingScreenModel` style B: lazy

Store the init parameters as ivars, then declare `viewModel` as a `lazy var` whose initializer constructs the ViewModel with all callbacks already wired in. Lazy initializers run after `init` completes, so the `[weak self]` capture is always valid.

```swift
@MainActor
public final class BookNoteListScreenModel: HostingScreenModel {
    public weak var viewController: UIViewController?
    private let book: Book
    private let libraryManager: LibraryManager

    public private(set) lazy var viewModel: BookNoteListViewModel = .init(
        book: book,
        selectNote: { [weak self] note in
            self?.handleSelect(note)
        },
    )

    public init(book: Book, libraryManager: LibraryManager) {
        self.book = book
        self.libraryManager = libraryManager

        Task.onChange(of: { libraryManager.notes(for: book.id) }) { [weak self] notes in
            self?.viewModel.notes = notes
        }.bind(to: self)
    }

    private func handleSelect(_ note: Note) {
        let next = SingleNoteScreen(noteId: note.id, libraryManager: libraryManager)
        viewController?.navigationController?.pushViewController(next, animated: true)
    }
}
```

This style allows the ViewModel's callback ivars to be **`let`** if you prefer that shape — they're supplied at construction time.

### Choosing between them

The two styles produce identical runtime behavior. The trade-offs are ergonomic:

|                                | Two-step                                                                   | Lazy                                                                       |
| ------------------------------ | -------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **ViewModel callbacks**        | Must be `var` (assigned after construction).                               | Can be `let` (supplied at construction).                                   |
| **Init body**                  | Construct, then wire callbacks. Procedural.                                | Trivial — just stash params. Wiring lives at the property declaration.     |
| **Init-param storage**         | Only what the model needs after init.                                      | Every parameter the lazy initializer references must be a stored ivar.     |
| **Construction timing**        | `viewModel` exists the moment `init` returns.                              | `viewModel` is created on first access — usually inside `HostingScreen.init`, but earlier if anything else reads it first. |
| **Discoverability**            | Obvious: read top-to-bottom.                                               | Requires knowing that `lazy` initializers can capture `[weak self]`.       |
| **Adding more wiring**         | Goes in the init body.                                                     | More wiring tends to push you back toward style A.                         |

Pick the one whose constraints best match the screen. A common pragmatic rule of thumb: if the ViewModel has one or two callbacks and you'd prefer a `let` shape, the lazy style reads cleaner; if the model's init has more procedural setup (multiple callbacks, observation tasks, conditional wiring), the two-step style stays more uniform with whatever else lives in `init`.

The included `Tests/SwiftUIExTests/ExampleStackTests.swift` demonstrates both shapes against the same `HostedView`/`HostingScreen` to show that they compose interchangeably.

## `RequirementCoordinator`

One additional type, scoped narrowly. Many apps have flows that look like *"gate the user through a list of reactive requirements — log in, complete profile, accept terms — and advance as each becomes satisfied."* That pattern composes cleanly into `@Observable` and is tedious to rewrite per-app, so SwiftUIEx ships it.

A `RequirementCoordinator` is built from an array of `RequirementCoordinatorNode`s; each node pairs a main-actor `isSatisfied` predicate with a main-actor `makeViewController` factory. The coordinator reads `isSatisfied` under `withObservationTracking`, so any mutation on any `@Observable` property the closure reads re-fires the check.

The canonical pattern is **prime → present → run**. `prime` does three things in a single synchronous call: reports whether anything needs to happen, attaches the nav controller to the coordinator, and places the first unsatisfied node's view controller on the nav. Because the first VC is on the nav before `present` is called, the presentation animation shows real content on its first frame — no blank-nav flash.

```swift
import SwiftUIEx
import UIKit

let coord = RequirementCoordinator(nodes: [
    .init(
        isSatisfied: { auth.isLoggedIn },
        makeViewController: { LoginScreen(auth: auth) }
    ),
    .init(
        isSatisfied: { profile.isComplete },
        makeViewController: { ProfileCompletionScreen(profile: profile) }
    ),
])

let nav = UINavigationController()

// 1. Prime. Returns false if every requirement is already satisfied — in
//    which case there is no flow to run and the caller can skip presenting
//    the nav controller entirely.
guard coord.prime(nav, animated: false) else {
    // proceed directly to whatever would follow the flow
    return
}

// 2. Present.
present(nav, animated: true)

// 3. Run.
Task {
    do {
        try await coord.run()
        // All requirements satisfied — caller decides what next.
        nav.dismiss(animated: true)
    } catch {
        // Task cancelled, or the nav was released — caller decides.
    }
}
```

### Push strategy

`prime` decides how to place the first view controller based on the nav's current state:

- **Empty nav:** `setViewControllers([vc], animated: false)`. The `animated:` argument is ignored — there's no meaningful source frame for an animation onto an empty stack.
- **Populated nav:** `pushViewController(vc, animated: animated)`. Honors the caller's choice.

This rule is what makes the coordinator *chain-friendly* against a shared nav: once a flow completes, a second coordinator can prime onto the same nav and its first screen will animate-push onto the stack the first flow left behind.

```swift
let nav = UINavigationController()

guard authCoord.prime(nav, animated: false) else { /* already authed */ }
present(nav, animated: true)
try await authCoord.run()

// Chain onto the same nav. Nav is now populated with authCoord's last
// screen, so the animated-push rule kicks in.
guard profileCoord.prime(nav, animated: true) else {
    nav.dismiss(animated: true)
    return
}
try await profileCoord.run()

nav.dismiss(animated: true)
```

Each coordinator is one-shot — calling `prime` twice on the same coordinator is a programming error and trips a precondition. Use a fresh coordinator per stage.

### API surface

- **`prime(_ nav: UINavigationController, animated: Bool) -> Bool`** — synchronous. Attaches the nav controller (weakly), places the first unsatisfied node's view controller on it, and returns `true` if there is a flow to run. Returns `false` when every node is already satisfied and leaves the nav controller untouched. Call exactly once per coordinator.
- **`run() async throws`** — asynchronous. Observes the current node's satisfaction via `withObservationTracking`, pauses `advanceDelay` (default 350 ms) between nodes so the user sees the success state, pushes subsequent unsatisfied nodes animated, and returns when every node is satisfied. Throws `CancellationError` on task cancellation, or if the nav controller is released before the next push.
- **`nodes.areAllSatisfied`** (Array extension) — pure point-in-time query. Use when you want to check completion state without attaching the coordinator to a nav or creating any view controllers.

### Lifetime details

- The coordinator holds the navigation controller **weakly**. If the caller dismisses and releases the nav without cancelling the `Task`, `run()` surfaces the disappearance as `CancellationError` on the next push rather than pinning the nav alive until satisfaction.
- Calling `run()` before `prime`, or after `prime` returned `false`, is a silent no-op. The canonical guard-on-prime pattern keeps this branch unreachable in correct code.
- If an external mutation satisfies the primed node in the narrow window between `prime` and `run()` (a rare race), `run()` detects the staleness and pushes the current first-unsatisfied node animated. The stale primed VC stays wherever it was in the stack.

### What it deliberately does **not** do

- It does not present anything. The caller owns presentation.
- It does not pop, dismiss, or otherwise modify the navigation controller on completion. When `run(in:)` returns, the last node's view controller is still on the stack, and the caller decides what to do with that (dismiss the nav controller, pop to root, push a result screen, etc).
- It does not detect "the user swiped the nav controller away" or similar external dismissals. If the owning Task is cancelled, the coordinator throws `CancellationError`; otherwise it simply waits for satisfaction.
- It does not require that the nodes' view controllers be `HostingScreen`s. Any `UIViewController` is fine — UIKit screens, SwiftUI screens, mixed.

This is deliberately *one* coordinator, not a coordinator *framework*. If you need a general-purpose routing primitive, this is not it — SwiftUIEx is opinionated about staying small, and the bar for a second coordinator type is the same bar the rest of the library lives by.

## Pairing with SwiftAsyncEx

SwiftUIEx makes the controller / view seam ergonomic; it does not provide the patterns you need to actually *react* to upstream `@Observable` state or to bound `Task`s by lifetime. Those belong in [SwiftAsyncEx](https://github.com/jmfieldman/SwiftAsyncEx), which is the lower-level companion library:

- **`Task.onChange(of:perform:)`** — re-arms `withObservationTracking` correctly so the `HostingScreenModel` can mirror manager state into the view-model on every change.
- **`Task.bound(to:)`** / **`TaskBag`** — binds spawned tasks to the model's lifetime, so observation loops and async work cancel cleanly when the screen goes away.
- **`SerialTask`**, **`LoadableResult`**, **`PersistentProperty`**, **demuxers** — the rest of the small-glue surface you tend to want from the model side.

Neither library depends on the other. SwiftAsyncEx is platform-light (iOS 17, no UIKit) by design; SwiftUIEx is UIKit-bound (iOS / tvOS / visionOS). Use either alone, or both together — the typical app uses both.

## Design principles

1. **Three screen-plumbing types plus one coordinator, and that's it.** The library exposes exactly `HostedView`, `HostingScreenModel`, `HostingScreen`, and the `RequirementCoordinator` / `RequirementCoordinatorNode` pair. If a sixth type is tempting, it probably belongs in the consuming app or in SwiftAsyncEx.
2. **No new state primitive.** No `@StateObject`-flavored wrapper, no Combine bridge, no stream type. Everything composes with `@Observable`, `let viewModel`, plain `var` properties, and plain closures.
3. **Strict on the contract, loose on the body.** The protocols pin down the wiring (`init(viewModel:)`, weak `viewController`, `viewModel` getter); they say nothing about how consumers shape their ViewModels or organize their dependencies.
4. **No lifecycle opinions.** `HostingScreen` does not override `viewDidLoad`, `viewWillAppear`, or any other UIKit lifecycle method. Subclasses and apps own appearance, layout-margin, and configuration concerns.
5. **`@MainActor` everywhere it touches state.** Every public type is `@MainActor` — the view, the model, the hosting controller. There are no off-actor escape hatches; Observation is synchronous, and the seam between UIKit and SwiftUI is on the main actor.

## Non-goals

- A general navigation or coordinator framework. Navigation is whatever you write in your `HostingScreenModel` against `viewController?.navigationController` — push, present, dismiss, custom transitions, your call. The one exception is the narrow `RequirementCoordinator` primitive described above, which is scoped tightly to reactive requirement-gate flows and is unopinionated about how its attached navigation controller is presented or torn down.
- A dependency-injection framework. The `HostingScreenModel` accepts whatever its `init` wants. Use Inject, use plain init parameters, use a service locator — orthogonal to this library.
- Anything Combine, ReactiveSwift, or stream-based. The whole point of this library is the `@Observable`-only commitment.
- Bridging into pure-SwiftUI navigation (`NavigationStack`, `NavigationPath`). Those work fine on their own — SwiftUIEx exists specifically because pure-SwiftUI navigation is not what every app uses.
- A replacement for `View.environment(_:)` or other built-in propagation. The model-vended-from-controller pattern is the seam between UIKit and SwiftUI; everything inside the SwiftUI subtree continues to use SwiftUI's own facilities.

## Requirements

- Swift 5.9+
- **iOS 17 / tvOS 17 / visionOS 1** — the Observation framework floor and the platforms where `UIHostingController` exists.

The package does not list macOS as a supported platform: `UIHostingController` (and `UIKit` generally) are not available on macOS, so the package cannot be built or imported there. Use Mac Catalyst if you need a Mac target.

## Installation

Add via Swift Package Manager:

```swift
.package(url: "https://github.com/jmfieldman/SwiftUIEx.git", from: "1.0.0")
```

and depend on the `SwiftUIEx` product from your target.

## Building and testing

The package depends on UIKit, so `swift build` / `swift test` on a macOS host cannot resolve `import UIKit`. Use `xcodebuild` against an iOS Simulator destination (the included `Makefile` does this):

```sh
make build       # xcodebuild build -scheme SwiftUIEx -destination 'platform=iOS Simulator,name=iPhone 17'
make test        # xcodebuild test  -scheme SwiftUIEx -destination 'platform=iOS Simulator,name=iPhone 17'
make format      # swift format --in-place --recursive Sources Tests
make lint        # swift format lint --strict --recursive Sources Tests
```

Override the destination as needed: `make test DESTINATION='platform=iOS Simulator,name=iPhone 16'`.

## License

MIT.

## Contributing

Issues proposing additional types are welcome, but the bar is deliberately high: **"this exact wiring repeats on every screen and the boilerplate has a real footgun."** If it can be expressed as a convention, a doc note, or a one-line helper inside a consuming app, it probably does not belong here.
