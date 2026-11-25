# Windows Hello IR-Only (Dark-Room Fix)

Restore **Windows Hello facial recognition in dark or low-light rooms** on Windows 11 **without disabling your RGB webcam** and without background lock/unlock scripts.

<img width="1200" height="675" alt="windows-hello-ir-only-reddit" src="https://github.com/user-attachments/assets/2b3ea190-6202-4702-a4ae-7ecd94a75199" />

## Why Windows Hello Stopped Working in the Dark

Starting with the April 2025 security updates addressing **CVE-2025-26644**, Microsoft changed Windows Hello Face authentication to require **both** the infrared (IR) sensor and the visible-light (RGB) webcam simultaneously. Because standard RGB webcams cannot see in pitch darkness, Windows Hello fails at night.

The common workaround—disabling the RGB webcam in Device Manager (or toggling it via background scripts on lock/unlock)—breaks video calls or introduces race conditions during sleep/wake and fails on in-session Windows Hello prompts (passkeys, UAC, password managers).

## How This Solution Works

Instead of disabling your RGB camera, `Enable-WindowsHelloIROnly.ps1` cleanly **decouples the RGB camera from Windows Hello's Media Foundation Sensor Group** while leaving the RGB camera 100% enabled for apps:

1. **Dynamic discovery (hardware- & language-agnostic):** Scans `KSCATEGORY_SENSOR_CAMERA` (`{24e552d7-6523-47f7-a647-d3465bf1f5ca}`) in the registry to find your IR camera's `FSSensorGroupId`, then finds the matching RGB camera interfaces (`KSCATEGORY_VIDEO_CAMERA`, `KSCATEGORY_CAPTURE`, `KSCATEGORY_VIDEO`).
2. **Automatic backups:** Exports `.reg` backups of every matched RGB `Device Parameters` key and writes a `manifest.json` before changing anything.
3. **Surgical decoupling (RGB only):** Removes `FSSensorGroupId`, `FSSensorGroupName`, and `Profiles\KSCAMERAPROFILE_FaceAuth_Mode,0` from the RGB camera interfaces only. Your IR sensor and `EnhancedAntiSpoofing` policy are left untouched.
4. **Rebuilds Sensor Group cache:** Stops `WbioSrvc`, `FrameServer`, and `FrameServerMonitor`, removes the cached `SWD\SGDEVAPI\*` software sensor group device, restarts the camera controller via `pnputil`, and restarts `WbioSrvc`.

Result:
- **Windows Hello** sees only the IR sensor and unlocks reliably in total darkness (boot, lock screen, and in-session prompts).
- **Your RGB webcam** remains permanently enabled for Camera, Microsoft Teams, Zoom, browsers, and Windows Studio Effects.

## Compatibility & Limitations

- **Verified on:** Microsoft Surface Laptop 7 (ARM64, Windows 11 Build 26300, `pt-PT`).
- **Windows Display Languages:** Works on **any** Windows language (uses only invariant GUIDs, registry keys, service names, and exit codes—no localized string parsing).
- **PowerShell:** Compatible with both **Windows PowerShell 5.1** and **PowerShell 7+**.
- **Other Windows 11 PCs:** Designed to work on any Windows 11 laptop/PC where FrameServer links the RGB and IR cameras via `FSSensorGroupId` and `SWD\SGDEVAPI`.
- **Where it does not apply:**
  - Single-sensor hybrid RGB+IR modules that share one hardware interface rather than separate RGB and IR endpoints.
  - USB/OEM camera drivers that do not use `FSSensorGroupId` / `SWD\SGDEVAPI`.
  - In both cases, `Check-WindowsHelloStatus.ps1` reports `STATUS: NOT_APPLICABLE` and `Enable-WindowsHelloIROnly.ps1` exits safely without changing anything.

## Security Trade-Off

Decoupling the RGB camera reverts Windows Hello facial recognition to IR-only authentication, which reduces the additional anti-spoofing mitigation introduced by Microsoft for **CVE-2025-26644** against sophisticated physical presentation attacks. Standard 3D infrared facial recognition remains active. Review this trade-off before applying on managed or high-security devices.

## Usage

Open **Terminal (Admin)** or **PowerShell (Run as Administrator)** in the repository folder:

### 1. Check current status (read-only, no Admin required)
```powershell
.\Check-WindowsHelloStatus.ps1
```
Reports `STATUS: LINKED`, `STATUS: ALREADY_SEPARATED`, or `STATUS: NOT_APPLICABLE`.

### 2. Preview changes safely (`-DryRun`)
```powershell
.\Enable-WindowsHelloIROnly.ps1 -DryRun
```

### 3. Apply IR-only mode (requires Administrator)
```powershell
powershell -ExecutionPolicy Bypass -File .\Enable-WindowsHelloIROnly.ps1
```
> **Note:** If a future OEM/Windows Update camera driver reinstalls the driver INF, it may restore the original `FSSensorGroupId` entries. Simply re-run `.\Enable-WindowsHelloIROnly.ps1` as Administrator.

### 4. Restore Microsoft's default behavior (requires Administrator)
```powershell
powershell -ExecutionPolicy Bypass -File .\Restore-WindowsHelloDefault.ps1
```
Automatically imports the latest timestamped `.reg` backup from `backups\`, clears the `SWD\SGDEVAPI` cache, and restarts the camera and biometric service.

## License

[MIT](LICENSE)
