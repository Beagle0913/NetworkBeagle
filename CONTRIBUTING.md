# Contributing to NetworkBeagle

Thanks for contributing.

## Development setup

1. Clone the repository.
2. Use Windows PowerShell 5.1+.
3. Run the GUI smoke check:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File ".\validation\gui_modular_smoke.ps1"`
4. Run tests:
   - `Invoke-Pester -Path .\tests`

## Pull request guidelines

- Keep changes focused and small where possible.
- Include a clear problem statement and rationale.
- Update docs for behavior changes.
- Add or update tests/smoke coverage for user-facing changes.
- Ensure CI passes before requesting review.

## Commit message style

Use concise, imperative summaries describing intent, for example:

- `Improve GUI validation coverage for advanced probe controls.`
- `Add one-click launcher documentation for non-terminal users.`

## Coding notes

- Keep entrypoint scripts thin and module-driven.
- Prefer extending `gui/core/*` modules instead of adding logic to entrypoints.
- Preserve compatibility with PowerShell 5.1.

## Reporting bugs and ideas

- Use GitHub Issues.
- Include reproduction steps, expected behavior, actual behavior, and logs/screenshots when possible.
