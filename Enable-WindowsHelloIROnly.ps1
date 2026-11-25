<#
.SYNOPSIS
    Decouples the RGB webcam from Windows Hello's Sensor Group so facial recognition
    uses only the IR sensor (restoring dark-room unlock) while keeping the RGB webcam enabled.

.PARAMETER DryRun
    Previews all registry keys, backups, SWD\SGDEVAPI devices, and camera device instances
    that would be modified or restarted, without making any changes.

.PARAMETER BackupDir
    Directory where timestamped .reg backups and manifest.json are stored.
    Defaults to a 'backups' subfolder next to this script.

.PARAMETER SkipVerification
    Skips post-apply verification checks.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$BackupDir = '',
    [switch]$SkipVerification
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $BackupDir = Join-Path $PSScriptRoot 'backups'
}
Add-Type -AssemblyName System.ServiceProcess

$SENSOR_CAMERA_GUID = '{24e552d7-6523-47f7-a647-d3465bf1f5ca}'
$RGB_CATEGORY_GUIDS = @(
    '{e5323777-f976-4f5b-9b55-b94699c46e44}', # KSCATEGORY_VIDEO_CAMERA
    '{65e8773d-8f56-11d0-a3b9-00a0c9223196}', # KSCATEGORY_CAPTURE
    '{6994ad05-93ef-11d0-a3cc-00a0c9223196}'  # KSCATEGORY_VIDEO
)
$DEVCLASSES_BASE = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CameraTopology {
    $irSensors = @()
    $irGroupIds = @{}
    $irDeviceInstances = @{}
    $irRefKeys = @{}

    $sensorRoot = Join-Path $DEVCLASSES_BASE $SENSOR_CAMERA_GUID
    if (Test-Path -LiteralPath $sensorRoot) {
        foreach ($ifaceKey in (Get-ChildItem -LiteralPath $sensorRoot -ErrorAction SilentlyContinue)) {
            $ifaceProps = Get-ItemProperty -LiteralPath $ifaceKey.PSPath -ErrorAction SilentlyContinue
            $devInstance = if ($null -ne $ifaceProps) { $ifaceProps.DeviceInstance } else { $null }

            foreach ($refKey in (Get-ChildItem -LiteralPath $ifaceKey.PSPath -ErrorAction SilentlyContinue)) {
                if ($refKey.PSChildName -notlike '#*') { continue }
                $irRefKeys[$refKey.PSChildName.ToLowerInvariant()] = $true

                $devParamsPath = Join-Path $refKey.PSPath 'Device Parameters'
                if (-not (Test-Path -LiteralPath $devParamsPath)) { continue }

                $dp = Get-ItemProperty -LiteralPath $devParamsPath -ErrorAction SilentlyContinue
                $groupId = if ($null -ne $dp) { $dp.FSSensorGroupId } else { $null }
                if (-not [string]::IsNullOrWhiteSpace($groupId)) {
                    $irGroupIds[$groupId.ToLowerInvariant()] = $true
                }
                if (-not [string]::IsNullOrWhiteSpace($devInstance)) {
                    $irDeviceInstances[$devInstance.ToLowerInvariant()] = $true
                }

                $irSensors += [PSCustomObject]@{
                    FriendlyName    = if ($null -ne $dp) { $dp.FriendlyName } else { $null }
                    DeviceInstance  = $devInstance
                    FSSensorGroupId = $groupId
                }
            }
        }
    }

    $matchedRgbEntries = @()
    foreach ($catGuid in $RGB_CATEGORY_GUIDS) {
        $catRoot = Join-Path $DEVCLASSES_BASE $catGuid
        if (-not (Test-Path -LiteralPath $catRoot)) { continue }

        foreach ($ifaceKey in (Get-ChildItem -LiteralPath $catRoot -ErrorAction SilentlyContinue)) {
            $ifaceProps = Get-ItemProperty -LiteralPath $ifaceKey.PSPath -ErrorAction SilentlyContinue
            $devInstance = if ($null -ne $ifaceProps) { $ifaceProps.DeviceInstance } else { $null }

            foreach ($refKey in (Get-ChildItem -LiteralPath $ifaceKey.PSPath -ErrorAction SilentlyContinue)) {
                if ($refKey.PSChildName -notlike '#*') { continue }
                if ($irRefKeys.ContainsKey($refKey.PSChildName.ToLowerInvariant())) { continue }

                $devParamsPath = Join-Path $refKey.PSPath 'Device Parameters'
                if (-not (Test-Path -LiteralPath $devParamsPath)) { continue }

                $dp = Get-ItemProperty -LiteralPath $devParamsPath -ErrorAction SilentlyContinue
                $groupId = if ($null -ne $dp) { $dp.FSSensorGroupId } else { $null }
                $hasGroupId = ($null -ne $dp.PSObject.Properties['FSSensorGroupId'])
                $hasGroupName = ($null -ne $dp.PSObject.Properties['FSSensorGroupName'])
                $faceAuthPath = Join-Path $devParamsPath 'Profiles\KSCAMERAPROFILE_FaceAuth_Mode,0'
                $hasFaceAuth = Test-Path -LiteralPath $faceAuthPath

                $matchesGroup = (-not [string]::IsNullOrWhiteSpace($groupId)) -and $irGroupIds.ContainsKey($groupId.ToLowerInvariant())
                $matchesParentFaceAuth = (-not [string]::IsNullOrWhiteSpace($devInstance)) -and $irDeviceInstances.ContainsKey($devInstance.ToLowerInvariant()) -and $hasFaceAuth

                if ($matchesGroup -or $matchesParentFaceAuth) {
                    $nativeRegKey = ($devParamsPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE', 'HKLM') -replace '^HKLM:', 'HKLM'
                    $matchedRgbEntries += [PSCustomObject]@{
                        CategoryGuid       = $catGuid
                        FriendlyName       = if ($null -ne $dp) { $dp.FriendlyName } else { $null }
                        DeviceInstance     = $devInstance
                        RegistryPath       = $devParamsPath
                        NativeRegKey       = $nativeRegKey
                        HasGroupId         = $hasGroupId
                        HasGroupName       = $hasGroupName
                        HasFaceAuthProfile = $hasFaceAuth
                        FaceAuthPath       = $faceAuthPath
                    }
                }
            }
        }
    }

    $uniqueInstances = @($matchedRgbEntries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DeviceInstance) } | Select-Object -ExpandProperty DeviceInstance -Unique)
    if ($uniqueInstances.Count -eq 0) {
        $uniqueInstances = @($irSensors | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DeviceInstance) } | Select-Object -ExpandProperty DeviceInstance -Unique)
    }

    $sgDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'SWD\SGDEVAPI\*' })

    return [PSCustomObject]@{
        IrSensors         = $irSensors
        IrGroupIds        = @($irGroupIds.Keys)
        MatchedRgbEntries = $matchedRgbEntries
        UniqueInstances   = $uniqueInstances
        SgDevApiDevices   = $sgDevices
    }
}

if (-not $DryRun -and -not (Test-IsAdministrator)) {
    Write-Error "Administrator privileges are required. Re-run this script from an elevated PowerShell terminal (Run as Administrator)."
    exit 1
}

$topology = Get-CameraTopology

if ($topology.IrSensors.Count -eq 0 -or $topology.IrGroupIds.Count -eq 0) {
    Write-Output "No Windows Hello IR sensor with FSSensorGroupId was found. No changes were made."
    exit 0
}

if ($topology.MatchedRgbEntries.Count -eq 0 -and $topology.SgDevApiDevices.Count -eq 0) {
    Write-Output "Nothing to change: RGB camera is already decoupled from the IR Sensor Group and no SWD\SGDEVAPI sensor group device is active."
    exit 0
}

if ($DryRun) {
    Write-Output "=== DRY RUN (no changes will be made) ==="
    Write-Output "IR sensors detected: $($topology.IrSensors.Count)"
    foreach ($entry in $topology.MatchedRgbEntries) {
        Write-Output "- Would back up and modify: $($entry.NativeRegKey)"
        if ($entry.HasGroupId) { Write-Output "    Remove value: FSSensorGroupId" }
        if ($entry.HasGroupName) { Write-Output "    Remove value: FSSensorGroupName" }
        if ($entry.HasFaceAuthProfile) { Write-Output "    Remove subkey: Profiles\KSCAMERAPROFILE_FaceAuth_Mode,0" }
    }
    foreach ($sg in $topology.SgDevApiDevices) {
        Write-Output "- Would remove cached PnP device: $($sg.InstanceId)"
    }
    foreach ($inst in $topology.UniqueInstances) {
        Write-Output "- Would restart PnP device: $inst"
    }
    Write-Output "- Would restart service: WbioSrvc"
    exit 0
}

# 1. Backup matched RGB Device Parameters registry keys
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionBackupDir = Join-Path $BackupDir $timestamp
New-Item -ItemType Directory -Path $sessionBackupDir -Force | Out-Null

$manifestEntries = @()
$index = 0
foreach ($entry in $topology.MatchedRgbEntries) {
    $index++
    $catClean = ($entry.CategoryGuid -replace '[\{\}]', '')
    $regFileName = "backup_${index}_${catClean}.reg"
    $regFilePath = Join-Path $sessionBackupDir $regFileName

    & reg.exe export $entry.NativeRegKey $regFilePath /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Registry backup failed (exit code $LASTEXITCODE) for: $($entry.NativeRegKey)"
        exit $LASTEXITCODE
    }
    if (-not (Test-Path -LiteralPath $regFilePath) -or ((Get-Item -LiteralPath $regFilePath).Length -le 0)) {
        Write-Error "Registry backup file is missing or empty: $regFilePath"
        exit 1
    }

    $manifestEntries += [PSCustomObject]@{
        CategoryGuid   = $entry.CategoryGuid
        FriendlyName   = $entry.FriendlyName
        DeviceInstance = $entry.DeviceInstance
        NativeRegKey   = $entry.NativeRegKey
        BackupFile     = $regFileName
    }
    Write-Output "Backed up: $($entry.NativeRegKey) -> $regFilePath"
}

$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$manifest = [PSCustomObject]@{
    CreatedAt                = (Get-Date -Format 'o')
    OSBuild                  = $osInfo.BuildNumber
    Entries                  = $manifestEntries
    DeviceInstancesToRestart = $topology.UniqueInstances
}
$manifestPath = Join-Path $sessionBackupDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output "Saved backup manifest: $manifestPath"

# 2. Remove Sensor Group linkage and FaceAuth profile from matched RGB keys only
foreach ($entry in $topology.MatchedRgbEntries) {
    if ($entry.HasGroupId) {
        Remove-ItemProperty -LiteralPath $entry.RegistryPath -Name 'FSSensorGroupId' -Force
        Write-Output "Removed FSSensorGroupId from $($entry.NativeRegKey)"
    }
    if ($entry.HasGroupName) {
        Remove-ItemProperty -LiteralPath $entry.RegistryPath -Name 'FSSensorGroupName' -Force
        Write-Output "Removed FSSensorGroupName from $($entry.NativeRegKey)"
    }
    if ($entry.HasFaceAuthProfile -and (Test-Path -LiteralPath $entry.FaceAuthPath)) {
        Remove-Item -LiteralPath $entry.FaceAuthPath -Recurse -Force
        Write-Output "Removed Profiles\KSCAMERAPROFILE_FaceAuth_Mode,0 from $($entry.NativeRegKey)"
    }
}

# 3. Stop biometric and FrameServer services
foreach ($svcName in @('WbioSrvc', 'FrameServer', 'FrameServerMonitor')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -ne $svc -and $svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        Write-Output "Stopped service: $svcName"
    }
}

# 4. Remove cached SWD\SGDEVAPI software sensor group devices
foreach ($sg in $topology.SgDevApiDevices) {
    Write-Output "Removing cached sensor group device: $($sg.InstanceId)"
    & pnputil.exe /remove-device $sg.InstanceId
    if ($LASTEXITCODE -ne 0) {
        Write-Error "pnputil /remove-device failed for $($sg.InstanceId) with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

# 5. Restart parent camera device instance(s)
foreach ($inst in $topology.UniqueInstances) {
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

# 6. Post-apply verification
if (-not $SkipVerification) {
    Write-Output ""
    Write-Output "=== Verification ==="
    $post = Get-CameraTopology
    if ($post.MatchedRgbEntries.Count -eq 0 -and $post.SgDevApiDevices.Count -eq 0) {
        Write-Output "Registry & PnP check: OK (RGB camera is decoupled from IR Sensor Group)."
    } else {
        Write-Warning "Post-check detected remaining RGB links ($($post.MatchedRgbEntries.Count)) or SGDEVAPI devices ($($post.SgDevApiDevices.Count)). A reboot may be required."
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime
            $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            })[0]
            [Windows.Media.Capture.Frames.MediaFrameSourceGroup, Windows.Media.Capture, ContentType=WindowsRuntime] | Out-Null
            $op = [Windows.Media.Capture.Frames.MediaFrameSourceGroup]::FindAllAsync()
            $asTask = $asTaskGeneric.MakeGenericMethod([System.Collections.Generic.IReadOnlyList[Windows.Media.Capture.Frames.MediaFrameSourceGroup]])
            $netTask = $asTask.Invoke($null, @($op))
            $netTask.Wait(-1) | Out-Null
            foreach ($g in $netTask.Result) {
                $kinds = @($g.SourceInfos | ForEach-Object { "$($_.DeviceInformation.Name):$($_.SourceKind)/$($_.MediaStreamType)" })
                Write-Output "- MediaFrameSourceGroup '$($g.DisplayName)' -> $($kinds -join '; ')"
            }
        } catch {
            Write-Warning "WinRT MediaFrameSourceGroup check skipped: $($_.Exception.Message)"
        }
    }
}

Write-Output ""
Write-Output "Done. Windows Hello is now configured for IR-only authentication while keeping your RGB webcam active."
