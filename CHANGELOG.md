# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project uses Semantic Versioning.

## [Unreleased]

### Added
- Added clearer PowerShell-first guidance, including GUI/CLI default parity notes and a dedicated CLI path in the README.
- Added missing comment-based help entries for monitoring and self-test parameters in the CLI entry script.
- Added targeted Pester coverage for GUI validation/runtime-rule behavior and CLI command export rendering.

### Changed
- Improved beginner GUI ergonomics with more plain-language helper copy and expanded Beginner mode section collapsing.
- Tightened CI workflow safety with read-only permissions, concurrency control, and pinned analyzer/test module versions.

### Fixed
- Prevented accidental commits of generated single-file bundle output by ignoring `network-stability-test.single.ps1`.
