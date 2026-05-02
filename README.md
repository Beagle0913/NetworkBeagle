# Network Stability Test GUI

Quick commands to start the GUI launcher.

## Start GUI (standard)

```powershell
Set-Location "C:\Users\Dziugas\Desktop\NetworkTest"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test-gui.ps1"
```

## Start GUI from current folder

If your terminal is already in the project directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\network-stability-test-gui.ps1"
```

## Run in full capabilities (admin)

Start normally, then click:

- `Run Full Capabilities (Admin)`

The launcher will request UAC elevation and continue with the same settings.

## Optional smoke check

```powershell
Set-Location "C:\Users\Dziugas\Desktop\NetworkTest"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\validation\gui_modular_smoke.ps1"
```

---

For full GUI details, see `network-stability-test-gui.md`.
