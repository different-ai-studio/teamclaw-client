# Repository Guidelines

## Project Structure & Module Organization

AMUX is split across three active areas. `daemon/` contains the Rust daemon (`src/agent`, `src/mqtt`, `src/supabase`, `src/teamclaw`). `ios/` contains the iOS app in `AMUXApp/` plus shared Swift packages in `Packages/AMUXCore`, `Packages/AMUXUI`, and `Packages/AMUXSharedUI`. `mac/` contains the macOS app and `Packages/AMUXMacUI`. Database work lives in `amux-api/` under `supabase/`. Shared schemas live in `proto/`. Treat `mac/build/`, `daemon/target/`, and SwiftPM `.build/` directories as generated output, not source.

## Build, Test, and Development Commands

Use the smallest command that matches the area you changed:

- `cd daemon && cargo build` builds the Rust daemon.
- `cd daemon && cargo test` runs daemon unit and integration tests.
- `./scripts/proto-gen-swift.sh` regenerates Swift protobuf files from `proto/`.
- `./scripts/run-mac.sh` rebuilds and launches the macOS app from `mac/AMUXMac.xcodeproj`.
- `cd amux-api && supabase start && supabase db reset && supabase test db` starts local Supabase, reapplies migrations, and runs DB tests.

For iOS and macOS app work, prefer Xcode for full app runs; package-level Swift tests live under each package’s `Tests/` directory.

## Coding Style & Naming Conventions

Follow existing language conventions. Rust uses `snake_case` for modules and functions, `PascalCase` for types, and should stay `rustfmt`-clean. Swift uses `UpperCamelCase` for types, `lowerCamelCase` for members, and 4-space indentation. Keep Swift package names aligned with directory names (`AMUXCore`, `AMUXUI`, `AMUXSharedUI`, `AMUXMacUI`). Generated protobuf files in `ios/Packages/AMUXCore/Sources/AMUXCore/Proto/` should only change via the generator script.

## Testing Guidelines

Add tests next to the module you touch: Rust tests under `daemon/src` or `daemon/tests` as appropriate, Swift tests under each package’s `Tests/*Tests` target. Name Swift test files after the subject, for example `TaskStoreTests.swift` or `SessionFiltersTests.swift`. Cover new logic paths and regressions before UI polish.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit prefixes such as `feat(daemon): ...`, `feat(ios): ...`, `chore(ios): ...`, and `refactor(ios): ...`. Keep scopes specific to the surface you changed. PRs should summarize behavior changes, list verification commands you ran, link the relevant issue or task, and include screenshots for visible iOS/macOS UI changes. Note any schema, config, or generated-code updates explicitly.

## Security & Configuration Tips

Do not commit secrets. The daemon expects Supabase values through `daemon/.env` or environment variables, and runtime config is written under `~/.config/amux/`. Review generated files and local config changes carefully before opening a PR.
