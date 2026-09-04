# Packages from Bangert Studio

`background_geo_tracker` is one of a family of open-source Flutter/Dart
packages published under the pub.dev publisher
[`contributors.info`](https://pub.dev/publishers/contributors.info/packages),
maintained by [Bangert Studio](https://www.bangertstudio.kz/). This page goes
one level deeper than the
[compact list in the README](README.md#also-from-bangert-studio); each package
still has its own README with the full API and examples.

- [State management](#state-management)
- [Forms](#forms)
- [Architecture](#architecture)
- [Navigation](#navigation)
- [UI utilities](#ui-utilities)
- [Tooling](#tooling)
- [Background and native](#background-and-native)

---

## State management

### [`apollon`](https://pub.dev/packages/apollon) — [source](https://github.com/AlexHCJP/apollon)

A minimal, dependency-free, Riverpod-inspired state container. `Provider<T>`
declares a lazy singleton around any `Listenable`; `ProviderScope` owns the
container, and `context.read(provider)` reads an instance from anywhere below
it, created on first access and cached from then on. Providers can depend on
each other through `container.watch()`, and `ApollonDebugScreen` lists every
live provider with its current value for debugging — there is no bespoke
`Consumer` widget, since plain `ListenableBuilder`/`ValueListenableBuilder`
already do the rebuilding.

### [`pike`](https://pub.dev/packages/pike) — [source](https://github.com/contributors-company/pike)

Event-driven state management: widgets `add()` an event, an internal handler
decides what happens next and `emit`s a new state, in the spirit of BLoC but
with a smaller surface. `PikeBuilder`, `PikeConsumer` and `PikeProvider` cover
rendering and wiring the instance through the widget tree, and `PikeObserver`
gives a single hook for logging every event and state transition.

---

## Forms

### [`fform`](https://pub.dev/packages/fform) — [source](https://github.com/AlexHCJP/fform)

Separates the form model from its widgets. `FFormField<T, E>` fields own their
value, validator and typed error; `FForm` composes fields — including nested
sub-forms — into one validity/state surface; `FFormBuilder`/`FFormProvider`
rebuild the UI from a stream of changes. Mixins add behaviour without
subclassing: `AsyncField` for asynchronous validation, `CachedField` for
reusing a previous value, `FocusedField` for focus tracking, `KeyedField` for
a stable widget key.

### [`fform_validator`](https://pub.dev/packages/fform_validator) — [source](https://github.com/AlexHCJP/fform_validator)

The string-validation half on its own: required, email, URL, IPv4/IPv6,
min/max length, case, credit-card-number checks. Works alongside `fform` or
standalone, wherever a value needs validating without pulling in a whole form
framework.

---

## Architecture

### [`depend`](https://pub.dev/packages/depend) — [source](https://github.com/AlexHCJP/depend)

Dependency injection that hands services out through `InheritedWidget` rather
than a global locator. A `DependencyFactory` builds a typed
`DependencyContainer` (sync or `Future`); `DependencyScope` creates it above a
subtree, shows a placeholder while it does, and disposes it on teardown;
`LazyGet`/`LazyFutureGet` defer constructing a given service until a widget
actually reads it, so an app doesn't pay the cost of every service at
startup.

---

## Navigation

### [`safe_route`](https://pub.dev/packages/safe_route) — [source](https://github.com/AlexHCJP/safe_route)

Removes the `Object? arguments` escape hatch from `Navigator.pushNamed`.
`SafeRoute<Arguments, Result>` gives every route two generic parameters, so
mismatched arguments or an unexpected pop result fail at compile time instead
of by casting `Object?` at runtime. `SafeRouter` registers routes and wires
`onGenerateRoute`; typed extensions (`pushRoute`, `popRoute`,
`pushReplacementRoute`, …) mirror the stock `Navigator` API one for one.

### [`map_route`](https://pub.dev/packages/map_route) — [source](https://github.com/AlexHCJP/map_route)

A development-time tool that renders an app's registered routes as a visual
graph, so a navigation structure built from many named routes can be
inspected rather than reconstructed by reading code. Meant for use while
developing, not for shipping in a release build.

---

## UI utilities

### [`responsive_breakpoints`](https://pub.dev/packages/responsive_breakpoints) — [source](https://github.com/AlexHCJP/responsive_breakpoints)

Resolves the current breakpoint through a `ThemeExtension` instead of
`MediaQuery` checks scattered through the widget tree. Ships ready-made
breakpoint enums for Tailwind, Bootstrap, Ant Design and Material 3, a
`BreakpointSpec` interface for defining a custom set, and comparison operators
(`<`, `>=`, …) for using them in conditions.

### [`enum_picker`](https://pub.dev/packages/enum_picker) — [source](https://github.com/AlexHCJP/enum_picker)

One widget, `EnumPicker<T>`, that turns any Dart enum into a Cupertino-style
bottom-sheet scroll picker and returns the value the user picked, or `null` on
dismiss — the few lines of picker boilerplate every app rewrites, written
once.

---

## Tooling

### [`markup_analyzer`](https://pub.dev/packages/markup_analyzer) — [source](https://github.com/AlexHCJP/markup_analyzer)

An `analysis_server_plugin`-based analyzer plugin — no code generation, no
build step — that flags string literals, interpolations and concatenations
passed straight into widget constructors, catching un-localized UI text
during analysis instead of in QA. Every check is configured independently, by
severity, in `analysis_options.yaml`.

### [`herdsman`](https://pub.dev/packages/herdsman) — [source](https://github.com/AlexHCJP/herdsman)

Manages Git hooks the way Husky does for Node projects. `--init` creates a
checked-in `.herdsman/githooks` directory and points Git at it, `--add`/
`--delete` manage individual hooks, and `--active` makes them executable — so
hooks travel with the repository instead of living only in a contributor's
local `.git/hooks`.

---

## Background and native

### [`background_geo_tracker`](https://pub.dev/packages/background_geo_tracker) — this repository

Native, continuous background route tracking for iOS and Android: the native
layer collects and uploads points on its own, without a live Dart isolate, and
resumes on its own after the app is backgrounded, evicted or the device is
rebooted. See the [README](README.md) for setup and the full API.

---

All of the above are licensed MIT or BSD-3-Clause; check each package's own
repository for its exact license.
