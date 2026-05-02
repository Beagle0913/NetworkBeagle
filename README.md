# NetworkBeagle

[![CI](https://github.com/Beagle0913/NetworkBeagle/actions/workflows/ci.yml/badge.svg)](https://github.com/Beagle0913/NetworkBeagle/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Windows-first network diagnostics for intermittent internet and LAN problems.

NetworkBeagle helps you collect reliable evidence over time instead of relying on one-off checks. It supports both a beginner-friendly GUI and a scriptable PowerShell CLI.

## Table of Contents

- [Quick Start](#quick-start)
- [What NetworkBeagle Does](#what-networkbeagle-does)
- [Requirements](#requirements)
- [Supported and Not Supported](#supported-and-not-supported)
- [Installation](#installation)
- [Usage](#usage)
- [Output and Evidence Files](#output-and-evidence-files)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Project Structure](#project-structure)
- [Contributing and Security](#contributing-and-security)
- [License](#license)

## Quick Start

Use this section if you want to run a diagnostic immediately.

### 1) Clone the repository

```powershell
git clone https://github.com/Beagle0913/NetworkBeagle.git
cd NetworkBeagle
```

### 2) Launch the tool

Easiest option:

- Double-click `Start-NetworkBeagle-GUI.cmd`

PowerShell options:

```powershell
# GUI
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test-gui.ps1"

# CLI
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1"
```

### 3) Run your first test

- In GUI: keep defaults (or pick a goal) and click **Run basic test**.
- In CLI: run with defaults first, then inspect generated report and CSV.

## What NetworkBeagle Does

NetworkBeagle is designed to answer practical questions:

- Is the issue local (PC, cable, NIC, router LAN)?
- Is the issue upstream (ISP or internet path)?
- Is DNS, TCP, TLS, or routing behavior involved?
- Can I generate evidence suitable for support or ISP escalation?

### Main capabilities

- Layered probes: loopback, gateway, external ICMP, optional TCP, optional TLS
- Optional advanced probes: continuous UDP and long-lived TCP session
- Route-context awareness with optional route refresh
- Optional config audit and cable/NIC hints on fault cycles
- Optional multi-NIC cross-check for stronger fault isolation
- Report + CSV + optional JSON summary + optional ISP evidence bundle

## Requirements

- OS: Windows
- PowerShell: 5.1 or newer
- Privileges: standard user works; admin is recommended for deepest diagnostics

## Supported and Not Supported

### Capability matrix

| Capability | Standard user | Administrator |
|---|---:|---:|
| Core ICMP diagnostics (loopback/gateway/external) | Supported | Supported |
| DNS/TCP/TLS probes | Supported | Supported |
| Basic report/CSV outputs | Supported | Supported |
| Strict multi-NIC pinning behavior | Limited | Supported |
| Auto-capture on fault (`pktmon` / `netshtrace`) | Limited | Supported |
| Fullest escalation evidence fidelity | Limited | Supported |

### Platform support

| Area | Status | Notes |
|---|---|---|
| Windows + PowerShell 5.1+ | Supported | Primary target platform |
| Non-Windows environments | Not supported | Scripts and GUI are Windows-specific |
| Local administrator rights | Optional | Recommended for deeper diagnostics |

## Installation

No installer is required.

1. Clone the repository (or download ZIP and extract).
2. Open PowerShell in the repository folder.
3. Run one of the launch commands from [Quick Start](#quick-start).

## Usage

### GUI usage (recommended for most users)

- Launch `Start-NetworkBeagle-GUI.cmd` or `network-stability-test-gui.ps1`.
- Use **Setup** for quick guided runs.
- Use **Advanced** for full parameter control.
- Use **Results** and **History** for review and repeatability.

### CLI usage (recommended for automation)

Baseline run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1"
```

Common examples:

```powershell
# Longer run with detailed cycle log
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1" `
  -DurationMinutes 240 `
  -DetailLog

# Enable TLS probe and zip ISP evidence
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1" `
  -EnableTlsProbe `
  -IspEvidenceZip

# Enable advanced continuous probes
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test.ps1" `
  -EnableUdpProbe -UdpProbeTarget "8.8.8.8:443" -UdpProbeRateHz 30 `
  -EnableLongLivedTcp -LongLivedTcpTarget "1.1.1.1:443"
```

Show full parameter help:

```powershell
Get-Help ".\network-stability-test.ps1" -Full
```

### When to choose GUI vs CLI

| Need | Choose GUI | Choose CLI |
|---|---:|---:|
| Fast guided run with presets | Yes | No |
| Non-technical handoff workflow | Yes | No |
| Repeatable automation / scripting | No | Yes |
| CI or scheduled tasks | No | Yes |
| Full interactive visibility while running | Yes | No |
| Command-level parameter composability | Limited | Yes |

## Output and Evidence Files

Typical artifacts per run:

- `network_report_<timestamp>.txt` - human-readable summary
- `network_log_<timestamp>.csv` - cycle timeline
- `network_detail_<timestamp>.log` - optional detailed cycle log
- `network_summary_<timestamp>.json` - optional machine-readable summary
- ISP evidence folder/zip - optional support package

### Output location behavior

CLI output fallback order:

1. `-OutputFolder` if writable
2. Script directory
3. `Desktop\NetworkTest`
4. `%TEMP%\NetworkTest`

GUI launch metadata folder:

- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\logs`

## Troubleshooting

### GUI does not start

Run GUI smoke validation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\validation\gui_modular_smoke.ps1"
```

Then check:

- `launcher.log`
- `stdout.log`
- `stderr.log`

### Output is empty or partial

- Confirm output folder permissions.
- Check launcher logs for early process exit.
- Run a short test first (for example, 5 to 15 minutes).

### Script execution policy prompts

Expected behavior: the provided launcher commands use session-scoped `ExecutionPolicy Bypass`.

## Development

### Run tests

```powershell
Invoke-Pester -Path .\tests
```

### Run linting

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

### Run GUI smoke checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\validation\gui_modular_smoke.ps1"
```

CI workflow (`.github/workflows/ci.yml`) runs parse checks, PSScriptAnalyzer, GUI smoke checks, and Pester.

## Project Structure

```text
NetworkBeagle/
  Start-NetworkBeagle-GUI.cmd
  Start-NetworkBeagle-GUI.ps1
  network-stability-test.ps1
  network-stability-test-gui.ps1
  lib/
  gui/core/
  gui/ui/layout.xaml
  validation/gui_modular_smoke.ps1
  tests/
  tools/bundle-single-file.ps1
```

## Contributing and Security

- Contributing guide: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Security policy: [`SECURITY.md`](SECURITY.md)
- Support: [`SUPPORT.md`](SUPPORT.md)
- Code of conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- Changelog: [`CHANGELOG.md`](CHANGELOG.md)

## Visual assets pending

Planned follow-up documentation additions:

- GUI screenshots for Setup, Live Run, and Results tabs
- Short GIF(s) for first-run flow and support bundle workflow

## License

MIT. See [`LICENSE`](LICENSE).
