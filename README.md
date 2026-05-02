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

---

## Part 1 — Easy to understand (for everyone)

You do **not** need to know how networks work in depth to use NetworkBeagle. Think of it as a **patient observer**: it checks your connection many times over minutes or hours and writes down what it saw, so you (or support) can spot patterns like “drops every evening” or “DNS slow but internet ping OK.”

### What you need

- A **Windows** PC (this project targets Windows and PowerShell 5.1+).
- The project folder on your machine (clone from GitHub or download a ZIP).

### The simplest way to run it (three steps)

1. **Open** the folder where you saved NetworkBeagle (the same folder that contains `Start-NetworkBeagle-GUI.cmd`).
2. **Double-click** `Start-NetworkBeagle-GUI.cmd`. A window titled something like “Network Stability Test Launcher” should open.
3. On the **Setup** tab, pick a **goal** if you want a suggested profile (for example “Quick internet sanity check”), check that the **save folder** looks right, then click **Run basic test**.

That starts a real diagnostic run. You can leave the window open; use the **Live Run** tab to watch high-level health while it works.

### Words you might see (plain meanings)

| Term (simple) | What it means here |
|---------------|---------------------|
| **Run / test** | A timed session where the tool repeatedly checks connectivity and records results. |
| **Output folder** | Where reports and logs are saved. You can change it in the GUI; pick a folder you can find later. |
| **Administrator / admin** | Windows “elevated” mode. Some deeper checks work better with admin rights; basic runs still work without it. |
| **CSV** | A spreadsheet-friendly timeline of measurements over time. |
| **Report** | A human-readable text summary of the run. |

### After it finishes — where to look (still simple)

- The GUI **Results** tab shows a short interpretation when data is available.
- On disk, the launcher keeps its own logs under your chosen output area, in a path like `gui-launcher-runs\run_<date-time>\logs`. **launcher.log**, **stdout.log**, and **stderr.log** are the first places to look if something looked wrong during the run.
- The main engine writes the **report**, **CSV**, and related files under the script’s run folder (see [What You Get from a Run](#what-you-get-from-a-run) and [Folder layout](#folder-layout) below).

### If you get stuck (non-technical checklist)

- **Nothing happens when you double-click the CMD file** — Try right-click → “Run as administrator” on `Start-NetworkBeagle-GUI.cmd`, or open PowerShell in that folder and run the command from [Quick Start (Power Users)](#quick-start-power-users).
- **Windows asks about “running scripts”** — That is normal. The provided launchers use `ExecutionPolicy Bypass` only for this session, for these scripts only.
- **You are not sure what settings to use** — Use a **goal card** on Setup (for example Quick check), or leave defaults and run once; you can always run again with a different goal.

When you are comfortable with the basics, the rest of this README explains **more detail**, **power-user options**, and **how the pieces fit together**.

---

## Part 2 — At a glance (quick reference)

If you only read one short block after Part 1:

1. Open the repo folder.
2. Double-click `Start-NetworkBeagle-GUI.cmd`.
3. On the **Setup** tab, press **Run basic test** (or choose a goal first, then run).

That gives you a useful baseline diagnostic run.

### Choose your path

- **Easiest path:** one-click GUI — `Start-NetworkBeagle-GUI.cmd`.
- **Terminal control:** PowerShell — `network-stability-test-gui.ps1` or `network-stability-test.ps1`.
- **Full internals:** [Deep dive (architecture + capabilities)](#deep-dive-architecture--capabilities) and `network-stability-test-gui.md`.

---

## Part 3 — GUI in a bit more detail (still approachable)

The launcher has **tabs** so you are not overwhelmed on the first screen.

| Tab | Plain purpose |
|-----|----------------|
| **Setup** | Choose a **goal** (preset), see a **run summary**, fix validation messages, and start or stop a run. **Preview command** / **Copy command** show the exact PowerShell that matches your settings. |
| **Live Run** | While a run is active (or after), see **health-style** summaries and **recent events**; raw log output is lower on the tab so it does not dominate. |
| **Results** | After a run, read **quick analysis**, open folders, copy paths, or create a **support bundle** (ZIP) when you need to send evidence to someone. |
| **History** | **Recent runs**, presets, re-run, and optional **compare two runs** side by side. |
| **Advanced** | Every **expert parameter** the CLI supports — same engine, full control. |

**Run basic test** runs with your current Windows user. **Run full diagnostic as administrator** may prompt for UAC and enables the deepest checks the tool can do on your machine.

More launcher-specific behavior (elevation, files per run, pointers like `latest-run.json`) is documented in `network-stability-test-gui.md`.

---

## Start Here (Easy Mode)

If you want to run it without learning the internals:

1. Clone or download this repository.
2. Open the project folder.
3. Double-click `Start-NetworkBeagle-GUI.cmd`.
4. On the **Setup** tab, keep defaults (or pick a goal), then press **Run basic test**.

---

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

### PowerShell-only path (recommended for automation)

If you want to operate fully from the terminal:

1. Start with the CLI (`network-stability-test.ps1`) and use `Get-Help ".\network-stability-test.ps1" -Full`.
2. If you configure a run in the GUI, use **Copy command** to export an equivalent command line.
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

---

## GUI defaults vs raw CLI defaults

The GUI and CLI both call the same engine (`network-stability-test.ps1`), but **GUI startup defaults** are tuned for guided use and do **not** match “CLI with no parameters” exactly.

Typical differences:

- `DetailLog` — often on in the GUI for clearer timelines.
- `RoutingRefreshIntervalCycles` — GUI may set periodic route refresh.
- `EnableTlsProbe` and `IspEvidenceZip` — may be enabled for stronger escalation signals on some profiles.

For **bit-for-bit reproducibility** between GUI and terminal:

1. Set options in the GUI (including Advanced if needed).
2. Use **Copy command**.
3. Run that exact command in PowerShell.

---

## What you get from a run

Artifacts depend on options, but commonly include:

| Artifact | Role |
|----------|------|
| `network_log_<timestamp>.csv` | Cycle-by-cycle timeline (spreadsheet-friendly). |
| `network_report_<timestamp>.txt` | Human-readable narrative report. |
| `network_detail_<timestamp>.log` | Optional verbose per-cycle log (`DetailLog`). |
| `network_summary_<timestamp>.json` | Optional machine-readable summary for tooling. |
| ISP evidence folder / zip | Optional package for provider escalation when enabled. |

### Output root resolution (CLI)

The script picks a writable output location in this order:

1. `OutputFolder` when valid and writable.
2. The script’s directory.
3. `Desktop\NetworkTest`.
4. `%TEMP%\NetworkTest`.

The GUI additionally creates **launcher run folders** under `<OutputRoot>\gui-launcher-runs\...` (see [Folder layout](#folder-layout)).

---

## Where to look first after a run

1. **GUI Results tab** — quick interpretation when the parser has enough data.
2. **`gui-launcher-runs\...\logs\launcher.log`** — launcher lifecycle (start, paths, errors).
3. **`stdout.log` / `stderr.log`** — raw engine output as captured by the launcher.
4. **Script run folder** — final report, CSV, and summaries for the diagnostic engine itself.

If you launched from the GUI, **`RUN_README.txt`** under the launcher run root summarizes those paths. **`gui-launcher-runs\latest-run.json`** points at the most recent launcher run metadata (when available).

---

## Deep dive (architecture + capabilities)

This section is for operators, support staff, and contributors who want the full diagnostic model.

### Design intent

- **Time series first** — intermittent issues hide in averages; NetworkBeagle emphasizes per-cycle records and trends.
- **Layered blame hints** — distinguish DNS vs gateway vs “beyond gateway” vs TLS/application-ish signals where probes allow.
- **Evidence-friendly** — optional captures, JSON summaries, and ISP-oriented bundles for tickets.

### Layered diagnostic model (each cycle)

Probing generally moves from the machine outward:

1. Loopback and adapter state/counters
2. Optional DNS timed probe
3. Underlay LAN gateway (when available) and primary gateway ICMP
4. External ICMP targets (multi-target, multi-attempt)
5. Optional TCP/443 probes
6. Optional TLS handshake probes

On non-OK cycles, additional context modules may run:

- Config audit (IP/subnet/proxy/events/power/MTU checks)
- Cable/NIC hints
- Multi-NIC cross-check (alternate adapter probing)
- Optional fault-triggered capture (`pktmon` / `netsh`)

### Major capability groups

**Probe and diagnosis**

- ICMP reliability + latency/jitter over time
- DNS responsiveness/failure tracking
- TCP reachability and optional TLS signal
- Route/underlay awareness with refresh intervals
- Wi-Fi signal snapshots
- Continuous UDP probe mode
- Long-lived TCP session probe
- Per-probe timestamping

**Fault enrichment**

- Burst-on-fault interval strategy
- Config audit and cable suspect heuristics
- Strict/loose multi-NIC cross-check logic
- Automatic capture-on-fault with bounded limits

**Reporting**

- Structured CSV + text report
- Optional JSON summary for downstream tooling
- Optional ISP evidence bundle/zip for escalation packages

### GUI-specific behavior (summary)

`network-stability-test-gui.ps1` provides:

- Tabbed workflow: **Setup**, **Live Run**, **Results**, **History**, **Advanced**
- Goal presets on Setup; full parameter surface on **Advanced**
- Live validation, dependent controls, and actionable fix hints where applicable
- Profile save/load (versioned JSON envelope for forward compatibility)
- Standard run vs elevated “full diagnostic” flow
- Live health dashboard, incident timeline, CLI export, support bundle ZIP, run comparison (History)

For file layouts, elevation details, and smoke validation, see **`network-stability-test-gui.md`**.

### Parameter model (families)

High-level groupings (see `Get-Help` for exact ranges and defaults):

- **Run timing** — `DurationMinutes`, `IntervalSeconds`, `MonitoringMode`, heartbeat/snapshot/event lookback
- **Probe targeting** — `ExternalIcmpHosts`, `DnsProbeName`, `TcpProbeHosts`, address family
- **Burst / fault behavior** — `BurstOnFault`, `BurstCycles`, `MaxBurstSeconds`, intervals
- **Routing** — `RoutingRefreshIntervalCycles`, `ProbeAddressFamily`
- **Optional modules** — `SkipConfigAudit`, `SkipCableHints`, `SkipMultiNicCrossCheck`, and related switches
- **Evidence** — `SkipIspEvidencePacket`, `IspEvidenceZip`, `SkipJsonSummary`
- **Advanced probes** — `EnableUdpProbe`, `EnableLongLivedTcp`, `EnableTlsProbe`
- **Diagnostics extras** — `PerProbeTimestamps`, `AutoCaptureOnFault`

Full authoritative documentation for every parameter:

```powershell
Get-Help ".\network-stability-test.ps1" -Full
```

### Folder layout

**GUI wrapper runs** (launcher-owned):

- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\` — launcher root (may include `RUN_README.txt`)
- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\logs` — `launcher.log`, `stdout.log`, `stderr.log`, `launch-config.json`, etc.
- `<OutputRoot>\gui-launcher-runs\run_<timestamp>\script-output-root` — value passed to the CLI as `-OutputFolder`

**Script runs** (engine-owned under the output folder you gave the script):

- `<OutputFolder>\runs\run_<timestamp>\...` — reports, CSV, detail logs, summaries

---

## Requirements and limitations

- **OS:** Windows (toolkit is Windows-first).
- **PowerShell:** 5.1 or later recommended; scripts use features aligned with 5.1+.
- **Admin:** Not strictly required for all probes, but **recommended** for strict multi-NIC behavior, packet capture paths, and richest evidence. The GUI labels this clearly on Setup.
- **Network policy:** Corporate firewalls or “guest” Wi-Fi may block some probe types; interpret “external” failures in that context.

---

## Troubleshooting (technical)

| Symptom | Things to check |
|---------|-------------------|
| GUI does not start | Run `validation\gui_modular_smoke.ps1`; confirm .NET/WPF availability on the machine; try launching via PowerShell to see errors in the console. |
| `Invoke-Pester` fails locally | CI pins Pester 4.x-compatible patterns; ensure Pester 4+ is installed, or run tests in CI. |
| Empty or partial CSV | Run duration and interval; confirm `OutputFolder` is writable; check stderr for early script exit. |
| Elevated run did not start | UAC cancel leaves the previous window open; check status text and `launcher.log`. |

---

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

GitHub Actions (`.github/workflows/ci.yml`) runs parse checks, PSScriptAnalyzer, GUI smoke validation, and Pester on pushes and pull requests.

---

## Project structure

```text
NetworkTest/
  Start-NetworkBeagle-GUI.cmd         # One-click launcher for non-terminal users
  Start-NetworkBeagle-GUI.ps1         # GUI preflight launcher
  network-stability-test.ps1          # CLI entrypoint
  network-stability-test-gui.ps1      # GUI entrypoint
  lib/                                # Probe, routing, audit, reporting modules
  gui/core/                           # GUI logic modules (state, validation, run-service, …)
  gui/ui/layout.xaml                  # WPF layout (tabs, Setup goals, Advanced)
  validation/gui_modular_smoke.ps1    # GUI parser / XAML smoke checks
  tests/                              # Pester tests (GUI state, report helpers, redesign helpers)
  tools/bundle-single-file.ps1        # Build single-file portable CLI script
  CHANGELOG.md                        # Notable changes between releases
```

---

## Single-file bundle

If you need to distribute without the `lib/` folder tree, build a one-file variant:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\bundle-single-file.ps1"
```

This creates `network-stability-test.single.ps1` with inlined library modules. That artifact is ignored by git (see `.gitignore`) to avoid accidental commits.

---

## Publishing and project health

- License: **`LICENSE`** (MIT)
- Security: **`SECURITY.md`**
- Contributing: **`CONTRIBUTING.md`**
- Support: **`SUPPORT.md`**
- Code of conduct: **`CODE_OF_CONDUCT.md`**
- Change history: **`CHANGELOG.md`**

---

## Operational notes

- Designed for **PowerShell 5.1+** on **Windows**.
- Some capabilities work best **with administrator rights** (strict multi-NIC pinning, capture flows, fuller evidence).
- **Non-admin** runs still produce valuable data; interpret “limited” banner text in the GUI as a hint, not a hard failure.
- For **best evidence quality** when escalating to an ISP or internal network team, use **Run full diagnostic as administrator** or launch the CLI elevated.
