# NetworkBeagle

[![CI](https://github.com/Beagle0913/NetworkBeagle/actions/workflows/ci.yml/badge.svg)](https://github.com/Beagle0913/NetworkBeagle/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Windows-focused network stability diagnostics with:

- a full PowerShell CLI runner (`network-stability-test.ps1`),
- a WPF GUI launcher (`network-stability-test-gui.ps1`),
- modular probe/audit libraries (`lib/*.ps1`),
- smoke checks and tests (`validation/`, `tests/`),
- optional ISP-ready evidence output.

This project is designed for long-running, layered diagnostics where short ping tests are not enough to explain intermittent failures.

## Publishing and project health

- License: `MIT` (see `LICENSE`)
- Security policy: `SECURITY.md`
- Contributing guide: `CONTRIBUTING.md`
- Support policy: `SUPPORT.md`
- Code of conduct: `CODE_OF_CONDUCT.md`
- Change history: `CHANGELOG.md`

## What the tool does

Each cycle inspects network behavior from local stack to upstream path:

1. Loopback and adapter state/counters
2. Optional DNS timed probe
3. Underlay LAN gateway (when resolved) and primary gateway ICMP
4. External ICMP targets (multiple targets, multiple pings per target)
5. Optional TCP/443 probes
6. Optional TLS handshake probes on top of TCP

On non-OK cycles, additional modules can run:

- config audit (IP/subnet/proxy/events/power/MTU checks),
- cable/NIC physical hints,
- multi-NIC cross-check (parallel alternate adapter probing),
- optional fault-triggered packet capture.

## Core capabilities

### Probe and diagnosis layers

- ICMP reliability and latency/jitter over time
- DNS responsiveness and failure tracking
- TCP reachability and optional TLS handshake signal
- Underlay/route awareness (including refresh intervals)
- Wi-Fi signal capture (SSID/BSSID/signal/radio/channel)
- Continuous UDP probe mode for micro-blackhole/TX-stall detection
- Long-lived TCP session probe for reset/timeout visibility
- Per-probe timestamping for cycle-level timing analysis

### Fault-context enrichment

- Burst-on-fault short-interval mode
- Device/network config audit on fault conditions
- Cable/NIC suspect heuristics
- Multi-NIC strict/loose cross-check logic
- Automatic capture-on-fault (`pktmon`/`netsh trace`) with limits

### Output and reporting

- CSV timeline with cycle-by-cycle metrics
- Human-readable text report
- Optional detail log narrative
- Optional JSON summary (`network_summary_<timestamp>.json`)
- Optional ISP evidence bundle + optional ZIP compression

## GUI launcher

`network-stability-test-gui.ps1` provides:

- full parameter surface of the CLI script,
- input validation for key runtime rules,
- preset application and profile save/load,
- standard run + UAC elevation relaunch flow,
- live log stream and health dashboard,
- post-run quick analysis and incident timeline parsing.

### Easy run (one-click GUI)

- Double-click `Start-NetworkBeagle-GUI.cmd`
- Or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Start-NetworkBeagle-GUI.ps1"
```

### Advanced run (PowerShell)

```powershell
Set-Location "<path-to-your-cloned-repo>"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test-gui.ps1"
```

For additional launcher details, see `network-stability-test-gui.md`.

## CLI usage

### Basic run

```powershell
Set-Location "<path-to-your-cloned-repo>"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1"
```

### Common examples

Run longer with detail logging:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1" `
  -DurationMinutes 240 `
  -DetailLog
```

Enable TLS signal + JSON summary + zipped ISP evidence:

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

## Major parameters

Main script supports extensive tuning, including:

- run timing (`DurationMinutes`, `IntervalSeconds`, monitoring mode),
- probe controls (`ExternalIcmpHosts`, `DnsProbeName`, `TcpProbeHosts`),
- fault behavior (`BurstOnFault`, `BurstCycles`, `MaxBurstSeconds`),
- route behavior (`RoutingRefreshIntervalCycles`, `ProbeAddressFamily`),
- optional modules (`SkipConfigAudit`, `SkipCableHints`, `SkipMultiNicCrossCheck`),
- evidence controls (`SkipIspEvidencePacket`, `IspEvidenceZip`, `SkipJsonSummary`),
- advanced probes (`EnableUdpProbe`, `EnableLongLivedTcp`, `EnableTlsProbe`),
- diagnostics extras (`PerProbeTimestamps`, `AutoCaptureOnFault`).

Run this to inspect the full parameter set with ranges/defaults:

```powershell
Get-Help ".\network-stability-test.ps1" -Full
```

## Output structure

The script writes to:

- `<OutputFolder>\runs\run_<timestamp>\...`

When `OutputFolder` is not writable/empty, fallback order is:

1. script directory,
2. `Desktop\NetworkTest`,
3. `%TEMP%\NetworkTest`.

Typical run artifacts include:

- `network_report_<timestamp>.txt`
- `network_log_<timestamp>.csv`
- `network_detail_<timestamp>.log` (when enabled)
- `network_summary_<timestamp>.json` (unless disabled)
- ISP evidence folder/zip (unless disabled)

GUI launcher runs create an additional wrapper folder:

- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\logs`
- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\script-output-root`

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
  tests/gui-state.tests.ps1           # Initial Pester coverage
  tools/bundle-single-file.ps1        # Build single-file portable CLI script
```

## Quality and validation

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

## Single-file bundle

If you need to distribute without `lib/`, build a one-file variant:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\bundle-single-file.ps1"
```

This creates `network-stability-test.single.ps1` with inlined library modules.

## Operational notes

- Designed for PowerShell 5.1+ on Windows.
- Some capabilities are best with admin rights (strict multi-NIC pinning, capture flows, fuller evidence capture).
- Non-admin mode still runs diagnostics, but with reduced strictness in specific areas.
- For best evidence quality in escalation scenarios, use GUI `Run Full Capabilities (Admin)` or launch elevated directly.
