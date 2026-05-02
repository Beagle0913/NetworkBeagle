# GUI Core Module Contracts

This folder implements the GUI launcher as focused modules with explicit roles.

## Module boundaries

- `state.ps1`
  - Owns canonical GUI state defaults and schema (`New-NetworkDiagGuiDefaultState`, `Get-NetworkDiagGuiStateSchema`).
  - Owns state merge/normalization (`Merge-NetworkDiagGuiState`).
  - Owns control <-> state mapping and CLI param map conversion.

- `validation.ps1`
  - Owns all form/business validation (`Test-NetworkDiagGuiState`).
  - Owns dependent-control enable/disable logic and validation rendering (`Invoke-NetworkDiagGuiValidation`).

- `run-service.ps1`
  - Owns run lifecycle transitions and state machine enforcement (`Set-NetworkDiagGuiRunState`, `Get-NetworkDiagGuiRunTransitionMap`).
  - Owns process launch mechanics and IO streaming.
  - Exposes testable launch helpers (`New-NetworkDiagGuiRunnerScriptContent`, `New-NetworkDiagGuiLaunchCommand`).

- `ui-events.ps1`
  - Owns UI event wiring only.
  - Delegates behavior to state/validation/run-service modules.

- `bootstrap.ps1`
  - Owns app composition root and module initialization sequence.
  - Does not contain run logic or business rules.

## Data flow

1. UI events call state extraction and validation.
2. Validated state is converted to script parameter map.
3. Run service starts process and streams output back to health/insights modules.
4. Run lifecycle updates are enforced through transition rules.
