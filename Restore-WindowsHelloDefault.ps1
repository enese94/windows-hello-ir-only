<#
.SYNOPSIS
    Restores the original Windows Hello RGB + IR Sensor Group configuration from backup.

.PARAMETER BackupDir
    Root folder containing timestamped backup directories. Defaults to 'backups' next to this script.

.PARAMETER BackupPath
    Optional explicit path to a specific timestamped backup directory containing manifest.json.
#>

[CmdletBinding()]
param(
    [string]$BackupDir = '',
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $BackupDir = Join-Path $PSScriptRoot 'backups'
}
Add-Type -AssemblyName System.ServiceProcess

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Administrator privileges are required. Re-run this script from an elevated PowerShell terminal (Run as Administrator)."
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
    $resolvedBackupDir = $BackupPath
} else {
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        Write-Error "Backup directory not found: $BackupDir"
        exit 1
    }
    $candidates = @(Get-ChildItem -LiteralPath $BackupDir -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')
    } | Sort-Object Name -Descending)
    if ($candidates.Count -eq 0) {
        Write-Error "No backup folder containing manifest.json was found in: $BackupDir"
        exit 1
    }
    $resolvedBackupDir = $candidates[0].FullName
}

$manifestPath = Join-Path $resolvedBackupDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Error "Backup manifest not found: $manifestPath"
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Write-Output "Restoring from backup: $resolvedBackupDir (created $($manifest.CreatedAt))"

foreach ($entry in $manifest.Entries) {
    $regFile = Join-Path $resolvedBackupDir $entry.BackupFile
    if (-not (Test-Path -LiteralPath $regFile)) {
        Write-Error "Missing backup registry file: $regFile"
        exit 1
    }
    & reg.exe import $regFile
    if ($LASTEXITCODE -ne 0) {
        Write-Error "reg import failed (exit code $LASTEXITCODE) for: $regFile"
        exit $LASTEXITCODE
    }
    Write-Output "Imported: $regFile"
}

foreach ($svcName in @('WbioSrvc', 'FrameServer', 'FrameServerMonitor')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -ne $svc -and $svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        Write-Output "Stopped service: $svcName"
    }
}

$sgDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'SWD\SGDEVAPI\*' })
foreach ($sg in $sgDevices) {
    Write-Output "Removing cached sensor group device for rebuild: $($sg.InstanceId)"
    & pnputil.exe /remove-device $sg.InstanceId
    if ($LASTEXITCODE -ne 0) {
        Write-Error "pnputil /remove-device failed for $($sg.InstanceId) with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

foreach ($inst in $manifest.DeviceInstancesToRestart) {
    if ([string]::IsNullOrWhiteSpace($inst)) { continue }
    Write-Output "Restarting PnP device: $inst"
    & pnputil.exe /restart-device $inst
    if ($LASTEXITCODE -ne 0) {
        Write-Error "pnputil /restart-device failed for $inst with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

Start-Sleep -Seconds 3
Start-Service -Name 'WbioSrvc'
$wbio = Get-Service -Name 'WbioSrvc'
if ($wbio.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
    Write-Error "WbioSrvc failed to start (current status: $($wbio.Status))."
    exit 1
}
Write-Output "WbioSrvc status: $($wbio.Status)"
Write-Output "Restore completed. Original Microsoft Windows Hello configuration is active."
