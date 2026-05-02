# Network Stability Test GUI Launcher

`network-stability-test-gui.ps1` is a WPF launcher for `network-stability-test.ps1`.

## Start

```powershell
Set-Location "C:\Users\Dziugas\Desktop\NetworkTest"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test-gui.ps1"
```

## What it covers

- Exposes all entry script parameters in UI controls.
- Validates the same key constraints as the script:
  - `ExternalIcmpHosts` must contain 2..6 entries.
  - `ExternalIcmpLabels` must be empty or match host count.
  - `TcpProbeHosts` must be empty or contain exactly 2 entries.
  - With `BurstOnFault`, `BurstIntervalSeconds` must be lower than `IntervalSeconds`.
  - Numeric controls enforce the same `ValidateRange` limits.
- Shows non-admin caveats and offers **Run Full Capabilities (Admin)** for UAC relaunch.

## Modular layout

The GUI entrypoint stays at:

- `network-stability-test-gui.ps1`

Core logic is split into modules:

- `gui/core/hooks.ps1` - lifecycle hooks/events (`RunStarting`, `CycleObserved`, `RunFinished`, etc.)
- `gui/core/layout.ps1` - XAML loader + control-name registry
- `gui/core/state.ps1` - default state + control/state mapping
- `gui/core/profiles.ps1` - presets + elevation handoff config persistence
- `gui/core/validation.ps1` - input validation + dependent-control toggles
- `gui/core/health-dashboard.ps1` - live health and trend calculations
- `gui/core/insights.ps1` - quick analysis + incident timeline parsing
- `gui/core/run-service.ps1` - run process orchestration
- `gui/core/ui-events.ps1` - all UI event wiring
- `gui/core/bootstrap.ps1` - app initialization and startup flow

UI markup lives in:

- `gui/ui/layout.xaml`

## Elevation behavior

- **Run (Standard)** starts the run without elevation.
- **Run Full Capabilities (Admin)**:
  - If already elevated, runs immediately.
  - If not elevated, relaunches the GUI with `RunAs` and restores selected settings from a temporary JSON file.
  - If UAC is canceled, the current GUI stays open and reports the cancellation.

## Folder structure

For each GUI launch run, the launcher creates:

- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\logs`
- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\script-output-root`

Launcher-side files in `logs`:

- `launcher.log` (status + lifecycle)
- `stdout.log` (captured script stdout)
- `stderr.log` (captured script stderr)
- `launch-config.json` (parameter snapshot used to launch)

The main script receives `-OutputFolder <...>\script-output-root` and then creates its own per-run output below that root (including report/csv/detail outputs).

## Notes on existing codebase limitations

- Non-admin runs still work, but some flows are less strict (for example multi-NIC strict route pinning).
- The GUI does not replace script-side validation; the script remains authoritative.
- `Open Current Run Folder` and `Open Current Logs Folder` become useful after a run starts and paths are known.

## Smoke validation

Run a lightweight modular smoke check:

```powershell
Set-Location "C:\Users\Dziugas\Desktop\NetworkTest"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\validation\gui_modular_smoke.ps1"
```
