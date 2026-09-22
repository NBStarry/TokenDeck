# Repository Guidelines

## Project Structure & Module Organization

TokenDeck is a Swift 6 macOS menu bar app built with SwiftPM. `Package.swift` defines one executable target at `Sources/UsageBar`. Core app entry and coordination live in `App.swift`, `MenuBarController.swift`, and `UsageStore.swift`; network, credential, cache, and configuration logic live in `Http.swift`, `CredentialStore.swift`, `UsageCache.swift`, `UsageFetcher.swift`, and `AppConfigStore.swift`. SwiftUI views are grouped under `Sources/UsageBar/Views`. `AppIcon.icns` and `make_icon.swift` support app icon generation. Treat `.build/` and `*.app/` as generated artifacts.

The repository also contains a Svelte/Rust Tauri implementation under `tauri/`, with Windows and Android-related work. For that implementation, read `tauri/README.md`, its package scripts and affected source/tests. Select validation by the implementation and platform actually changed; a Swift-only edit does not require unrelated Windows acceptance.

## Build, Test, and Development Commands

- `swift build`: compile the debug executable.
- `swift build -c release`: compile the optimized release binary.
- `./build-app.sh`: build release, assemble `TokenDeck.app`, embed the icon, and ad-hoc sign the bundle.
- `open TokenDeck.app`: run the bundled menu bar app after packaging.
- `.build/release/TokenDeck --fetch claude` or `.build/release/TokenDeck --fetch codex`: validate fetcher behavior without launching the GUI.
- `.build/release/TokenDeck --render-readme`: regenerate README interface screenshots.
- `swift test`: run the `TokenDeckTests` SwiftPM target under `Tests/TokenDeckTests`. Rust tests under `tauri/` are separate.

The fetch commands access real account/network state; app launch and screenshot generation have runtime effects. Run them only when the current task includes that validation, not for a documentation-only edit. For Tauri, use the commands documented in `tauri/README.md` and `tauri/package.json`.

## Coding Style & Naming Conventions

Use idiomatic Swift with 4-space indentation and descriptive type names in `UpperCamelCase`. Keep methods, properties, and local variables in `lowerCamelCase`. Prefer small, focused SwiftUI views and keep shared styling in `Theme.swift`. Use structured APIs such as `URLSession`, `Codable`, and `FileManager` rather than ad hoc parsing.

Avoid comments that merely repeat the code. Preserve or add useful explanations of safety boundaries, non-obvious compatibility behavior and protocol constraints. Compiler/tool directives (including Swift tools-version), shebangs and license text are permitted. Run comment checks only when an actual maintained checker exists and the changed source is in its scope; do not require an unimplemented hook or a comment quota.

## Requirement Scope Discipline

Implement the requirements explicitly stated by 北桥 and their necessary implementation, documentation and validation. Do not add unrelated features, refactors, cleanup or future-proofing. An assigned requirement ID must be preserved; an ordinary task without an ID maps directly to the user's request and acceptance criteria. Routine in-scope changes can proceed; new scope, permissions, destructive data changes or material costs require corresponding authorization.

Keep each diff traceable to that scope. Independent review is a merge/release gate when that workflow is requested, not a reason to leave completed local implementation unfinished. Reviewers use the original request, actual target diff and applicable existing checks; platform acceptance covers only affected platforms. Report local completion separately from pending review or device acceptance.

## Testing Guidelines

The Swift implementation has a `TokenDeckTests` target; the Tauri implementation has Rust tests. Reuse relevant existing tests and add focused cases around parsing, caching, configuration defaults and error handling when warranted. Name tests by behavior. Do not add a test framework or cross-platform validation solely for prose changes.

## Commit & Pull Request Guidelines

Inspect the actual Git history when preparing an authorized commit; this checkout has Git history. Use short imperative subjects consistent with recent relevant commits. Keep related code and documentation together. Pull requests should include a summary, actual verification, linked issues when applicable, and screenshots or recordings for UI changes. Editing does not itself authorize commit, push or publication.

## Security & Configuration Tips

Do not commit local credentials or generated config from `~/.config/usage-bar/`. Keep token handling inside `CredentialStore.swift` and avoid logging bearer tokens, account IDs, or raw API responses that may contain private usage data.
