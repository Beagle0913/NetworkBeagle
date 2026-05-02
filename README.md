# NetworkBeagle

[![CI](https://github.com/Beagle0913/NetworkBeagle/actions/workflows/ci.yml/badge.svg)](https://github.com/Beagle0913/NetworkBeagle/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

NetworkBeagle is a Windows-first network diagnostics toolkit for finding intermittent connectivity problems that short tests often miss.

It includes:

- a full PowerShell CLI runner (`network-stability-test.ps1`)
- a WPF GUI launcher (`network-stability-test-gui.ps1`)
- a one-click launcher for non-technical users (`Start-NetworkBeagle-GUI.cmd`)
- modular probe/audit libraries (`lib/*.ps1`)
- smoke checks and tests (`validation/`, `tests/`)
- optional ISP-ready evidence output

## At a Glance

If you only read one section, read this:

1. Open the repo folder.
2. Double-click `Start-NetworkBeagle-GUI.cmd`.
3. Press `Run basic test` in the GUI Setup tab.

That gives you a useful baseline diagnostic run.

## Choose Your Path

- **I want the easiest path:** use the one-click GUI launcher (`Start-NetworkBeagle-GUI.cmd`).
- **I prefer terminal control:** use PowerShell commands (`network-stability-test-gui.ps1` or `network-stability-test.ps1`).
- **I need internals and full behavior:** jump to [Deep Dive (Architecture + Capabilities)](#deep-dive-architecture--capabilities).

## Start Here (Easy Mode)

If you want to run it without learning the internals:

1. Clone/download this repository.
2. Open the project folder.
3. Double-click `Start-NetworkBeagle-GUI.cmd`.
4. In the GUI Setup tab, keep defaults and press `Run basic test`.

## Quick Start (Power Users)

### Run GUI from PowerShell

```powershell
Set-Location "<path-to-your-cloned-repo>"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test-gui.ps1"
```

### Run CLI directly

```powershell
Set-Location "<path-to-your-cloned-repo>"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1"
```

### PowerShell-only path (recommended)

If you want to operate fully from terminal:

1. Start with direct CLI (`network-stability-test.ps1`) and use `Get-Help ".\network-stability-test.ps1" -Full`.
2. If you configure a run in the GUI, use `Copy PowerShell Command` to export an equivalent command.
3. Replace placeholder output paths and re-run from PowerShell for repeatable automation.

### Common CLI examples

Longer run with detailed per-cycle narrative:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1" `
  -DurationMinutes 240 `
  -DetailLog
```

Enable TLS signal and zip ISP evidence:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1" `
  -EnableTlsProbe `
  -IspEvidenceZip
```

Enable advanced continuous probes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1" `
  -EnableUdpProbe -UdpProbeTarget "8.8.8.8:443" -UdpProbeRateHz 30 `
  -EnableLongLivedTcp -LongLivedTcpTarget "1.1.1.1:443"
```

## GUI Defaults vs Raw CLI Defaults

GUI and CLI execute the same engine (`network-stability-test.ps1`), but GUI startup defaults are intentionally tuned for guided operation and do not exactly match "CLI with no parameters".

Examples where GUI defaults are typically more opinionated:

- `DetailLog` (GUI commonly enables it)
- `RoutingRefreshIntervalCycles` (GUI may set periodic refresh)
- `EnableTlsProbe` and `IspEvidenceZip` (GUI may enable convenience/signal defaults)

If you need exact reproducibility between GUI and terminal:

1. Set options in GUI.
2. Use `Copy PowerShell Command`.
3. Run that exported command in PowerShell.

## What You Get from a Run

- cycle-by-cycle CSV timeline (`network_log_<timestamp>.csv`)
- human-readable report (`network_report_<timestamp>.txt`)
- optional detail narrative log (`network_detail_<timestamp>.log`)
- optional machine-readable summary (`network_summary_<timestamp>.json`)
- optional ISP evidence folder (+ zip if enabled)

Output root behavior:

1. Uses `OutputFolder` when valid/writable.
2. Falls back to script directory.
3. Then `Desktop\NetworkTest`.
4. Then `%TEMP%\NetworkTest`.

## Where To Look First After a Run

- Open `gui-launcher-runs\...\logs\launcher.log` for launcher lifecycle events.
- Open `stdout.log` / `stderr.log` for live process output.
- Open the script output run folder for the final report and CSV.

## Deep Dive (Architecture + Capabilities)

This section is for users/operators who want to understand the full diagnostic model.

### Layered diagnostic model

Each cycle probes from local system outwards:

1. Loopback and adapter state/counters
2. Optional DNS timed probe
3. Underlay LAN gateway (when available) and primary gateway ICMP
4. External ICMP targets (multi-target, multi-attempt)
5. Optional TCP/443 probes
6. Optional TLS handshake probes

On non-OK cycles, additional context modules can run:

- config audit (IP/subnet/proxy/events/power/MTU checks)
- cable/NIC hints
- multi-NIC cross-check (parallel alternate adapter probing)
- optional fault-triggered capture (`pktmon`/`netsh`)

### Major capability groups

**Probe and diagnosis**
- ICMP reliability + latency/jitter over time
- DNS responsiveness/failure tracking
- TCP reachability and optional TLS signal
- route/underlay awareness with refresh intervals
- Wi-Fi signal snapshots
- continuous UDP probe mode
- long-lived TCP session probe
- per-probe timestamping

**Fault enrichment**
- burst-on-fault interval strategy
- config audit and cable suspect heuristics
- strict/loose multi-NIC cross-check logic
- automatic capture-on-fault with bounded limits

**Reporting**
- structured CSV + text report
- optional JSON summary for downstream tooling
- optional ISP evidence bundle/zip for escalation packages

### GUI-specific behavior

`network-stability-test-gui.ps1` provides:

- tabbed workflow (`Setup`, `Live Run`, `Results`, `History`, `Advanced`)
- full parameter surface for the CLI
- live validation + dependent control enablement
- presets and profile save/load
- standard run and elevated relaunch flow
- live health dashboard and incident timeline
- CLI export and artifact path helpers

For deeper GUI internals, see `network-stability-test-gui.md`.

### Parameter model

High-level parameter families:

- run timing (`DurationMinutes`, `IntervalSeconds`, `MonitoringMode`)
- probe targeting (`ExternalIcmpHosts`, `DnsProbeName`, `TcpProbeHosts`)
- burst/fault behavior (`BurstOnFault`, `BurstCycles`, `MaxBurstSeconds`)
- routing controls (`RoutingRefreshIntervalCycles`, `ProbeAddressFamily`)
- optional modules (`SkipConfigAudit`, `SkipCableHints`, `SkipMultiNicCrossCheck`)
- evidence output (`SkipIspEvidencePacket`, `IspEvidenceZip`, `SkipJsonSummary`)
- advanced probes (`EnableUdpProbe`, `EnableLongLivedTcp`, `EnableTlsProbe`)
- diagnostics extras (`PerProbeTimestamps`, `AutoCaptureOnFault`)

See full script help for exact ranges/defaults:

```powershell
Get-Help ".\network-stability-test.ps1" -Full
```

### Folder layout

GUI wrapper runs use:

- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\logs`
- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\script-output-root`

Script runs use:

- `<OutputFolder>\runs\run_<timestamp>\...`

## Quality and validation

Run these when changing code:

### Smoke check

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\validation\gui_modular_smoke.ps1"
```

### Tests

```powershell
Invoke-Pester -Path .\tests
```

### Linting

PSScriptAnalyzer settings are in `PSScriptAnalyzerSettings.psd1`.

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

A GitHub Actions workflow is included in `.github/workflows/ci.yml` to run parse checks, analyzer, smoke validation, and tests on Windows.

## Project structure

```text
NetworkTest/
  Start-NetworkBeagle-GUI.cmd         # One-click launcher for non-terminal users
  Start-NetworkBeagle-GUI.ps1         # GUI preflight launcher
  network-stability-test.ps1          # CLI entrypoint
  network-stability-test-gui.ps1      # GUI entrypoint
  lib/                                # Probe, routing, audit, reporting modules
  gui/core/                           # GUI logic modules
  gui/ui/layout.xaml                  # WPF layout
  validation/gui_modular_smoke.ps1    # GUI parser/XAML smoke checks
  tests/gui-state.tests.ps1           # Pester coverage
  tools/bundle-single-file.ps1        # Build single-file portable CLI script
```

## Single-file bundle

If you need to distribute without `lib/`, build a one-file variant:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\bundle-single-file.ps1"
```

This creates `network-stability-test.single.ps1` with inlined library modules.

## Publishing and project health

- License: `MIT` (see `LICENSE`)
- Security policy: `SECURITY.md`
- Contributing guide: `CONTRIBUTING.md`
- Support policy: `SUPPORT.md`
- Code of conduct: `CODE_OF_CONDUCT.md`
- Change history: `CHANGELOG.md`

## Operational notes

- Designed for PowerShell 5.1+ on Windows.
- Some capabilities are best with admin rights (strict multi-NIC pinning, capture flows, fuller evidence capture).
- Non-admin mode still runs diagnostics, but with reduced strictness in specific areas.
- For best evidence quality in escalation scenarios, use GUI `Run full diagnostic as administrator` or launch elevated directly.
