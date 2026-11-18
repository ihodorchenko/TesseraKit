# Contributing to TesseraKit

Thanks for your interest. Bug reports, fixes, documentation and focused feature work are all welcome.

## Building and testing

```bash
swift build --triple arm64-apple-ios15.0-simulator
xcrun simctl list devices available     # pick an iPhone simulator
xcodebuild test -scheme TesseraKit-Package -destination 'platform=iOS Simulator,name=<iPhone name>'
```

The package is iOS-only, so `swift build` and `swift test` on a macOS host do not cover UIKit code. To check
behaviour by hand, run the Example app (`Example/TesseraKitExample/TesseraKitExample.xcodeproj`); the
[manual testing checklist](docs/MANUAL-TESTING.md) lists scenarios that unit tests cannot cover.

## Code style

- Swift 5.9, iOS 15 deployment target: no newer APIs (no `@Observable`, `scrollTargetBehavior`, `@Entry`).
- Public top-level types use the `Tessera` prefix; nested types do not need it.
- Public declarations carry `///` documentation comments.
- Follow the contracts in [AGENTS.md](AGENTS.md): a single progress scalar, a single writer of `contentOffset`,
  only `frame`/`transform`/`alpha` work in scroll callbacks.
- Components depend only on `TesseraCore`. A mechanism moves into Core only if two components need it.
- No external dependencies.

## Pull request checklist

- [ ] The change builds and all tests pass.
- [ ] New behaviour has tests under `Tests/<Target>Tests`.
- [ ] Accessibility is covered: VoiceOver, Reduce Motion, Dynamic Type, RTL.
- [ ] Public API changes are documented, and `TesseraCore` changes go through deprecation.
- [ ] Affected documents in `docs/` and the [changelog](CHANGELOG.md) are updated.
- [ ] Commit messages and the PR description are in English; the PR is small and focused.

## Decision log

Notable design decisions are recorded in [docs/DECISIONS.md](docs/DECISIONS.md) (ids `D<n>`) and risks in
[docs/RISKS.md](docs/RISKS.md). Read the relevant entries before changing behaviour, and add a new entry when
you make a lasting decision.

## Reporting issues

Use the issue templates. Include the iOS version, device or simulator, a minimal reproduction and what you
expected. For security problems follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Code of conduct

Be respectful and constructive. Assume good faith, keep feedback about the work and not the person, and do not
harass or discriminate. Maintainers may remove comments or contributions that break these expectations.
