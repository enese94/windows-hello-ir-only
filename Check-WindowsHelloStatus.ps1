<#
.SYNOPSIS
    Read-only diagnostic for Windows Hello IR/RGB Sensor Group configuration.

.DESCRIPTION
    Inspects Windows Media Foundation camera DeviceClasses, active SWD\SGDEVAPI
    software sensor groups, live MediaFrameSourceGroups (on Windows PowerShell 5.1),
    and Windows Biometric Service (WbioSrvc) status without modifying the system.
    Works across all Windows display languages.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.ServiceProcess

$SENSOR_CAMERA_GUID = '{24e552d7-6523-47f7-a647-d3465bf1f5ca}'
$RGB_CATEGORY_GUIDS = @(
    '{e5323777-f976-4f5b-9b55-b94699c46e44}', # KSCATEGORY_VIDEO_CAMERA
    '{65e8773d-8f56-11d0-a3b9-00a0c9223196}', # KSCATEGORY_CAPTURE
    '{6994ad05-93ef-11d0-a3cc-00a0c9223196}'  # KSCATEGORY_VIDEO
)
$DEVCLASSES_BASE = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses'

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
                $groupName = if ($null -ne $dp) { $dp.FSSensorGroupName } else { $null }
                $friendly = if ($null -ne $dp) { $dp.FriendlyName } else { $null }
                $hasFaceAuth = Test-Path -LiteralPath (Join-Path $devParamsPath 'Profiles\KSCAMERAPROFILE_FaceAuth_Mode,0')

                if (-not [string]::IsNullOrWhiteSpace($groupId)) {
                    $irGroupIds[$groupId.ToLowerInvariant()] = $true
                }
                if (-not [string]::IsNullOrWhiteSpace($devInstance)) {
                    $irDeviceInstances[$devInstance.ToLowerInvariant()] = $true
                }

                $irSensors += [PSCustomObject]@{
                    FriendlyName       = $friendly
                    DeviceInstance     = $devInstance
                    RefKey             = $refKey.PSChildName
                    FSSensorGroupId    = $groupId
                    FSSensorGroupName  = $groupName
                    HasFaceAuthProfile = $hasFaceAuth
                    RegistryPath       = $devParamsPath
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
                $groupName = if ($null -ne $dp) { $dp.FSSensorGroupName } else { $null }
                $friendly = if ($null -ne $dp) { $dp.FriendlyName } else { $null }
                $hasFaceAuth = Test-Path -LiteralPath (Join-Path $devParamsPath 'Profiles\KSCAMERAPROFILE_FaceAuth_Mode,0')

                $matchesGroup = (-not [string]::IsNullOrWhiteSpace($groupId)) -and $irGroupIds.ContainsKey($groupId.ToLowerInvariant())
                $matchesParentFaceAuth = (-not [string]::IsNullOrWhiteSpace($devInstance)) -and $irDeviceInstances.ContainsKey($devInstance.ToLowerInvariant()) -and $hasFaceAuth

                if ($matchesGroup -or $matchesParentFaceAuth) {
                    $matchedRgbEntries += [PSCustomObject]@{
                        CategoryGuid       = $catGuid
                        FriendlyName       = $friendly
                        DeviceInstance     = $devInstance
                        RefKey             = $refKey.PSChildName
                        FSSensorGroupId    = $groupId
                        FSSensorGroupName  = $groupName
                        HasFaceAuthProfile = $hasFaceAuth
                        RegistryPath       = $devParamsPath
                    }
                }
            }
        }
    }

    $sgDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'SWD\SGDEVAPI\*' })

    return [PSCustomObject]@{
        IrSensors          = $irSensors
        IrGroupIds         = @($irGroupIds.Keys)
        MatchedRgbEntries  = $matchedRgbEntries
        SgDevApiDevices    = $sgDevices
    }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Output "=== System Info ==="
Write-Output "OS: $($os.Caption) | Build: $($os.BuildNumber) | Arch: $($os.OSArchitecture)"
Write-Output "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

$topology = Get-CameraTopology

Write-Output ""
Write-Output "=== IR Sensors (KSCATEGORY_SENSOR_CAMERA) ==="
if ($topology.IrSensors.Count -eq 0) {
    Write-Output "None found."
} else {
    foreach ($ir in $topology.IrSensors) {
        Write-Output "- $($ir.FriendlyName) | Instance: $($ir.DeviceInstance) | GroupId: $($ir.FSSensorGroupId) | FaceAuthProfile: $($ir.HasFaceAuthProfile)"
    }
}

Write-Output ""
Write-Output "=== RGB Camera Interfaces Linked to IR Sensor Group ==="
if ($topology.MatchedRgbEntries.Count -eq 0) {
    Write-Output "None found."
} else {
    foreach ($rgb in $topology.MatchedRgbEntries) {
        Write-Output "- $($rgb.FriendlyName) ($($rgb.CategoryGuid)) | Instance: $($rgb.DeviceInstance) | GroupId: $($rgb.FSSensorGroupId) | FaceAuthProfile: $($rgb.HasFaceAuthProfile)"
    }
}

Write-Output ""
Write-Output "=== Cached SWD\SGDEVAPI Software Devices ==="
if ($topology.SgDevApiDevices.Count -eq 0) {
    Write-Output "None found."
} else {
    foreach ($sg in $topology.SgDevApiDevices) {
        Write-Output "- $($sg.FriendlyName) | Status: $($sg.Status) | InstanceId: $($sg.InstanceId)"
    }
}

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Write-Output ""
    Write-Output "=== Live MediaFrameSourceGroups ==="
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
            Write-Output "- Group '$($g.DisplayName)' -> $($kinds -join '; ')"
        }
    } catch {
        Write-Output "Unable to query WinRT MediaFrameSourceGroup: $($_.Exception.Message)"
    }
}

Write-Output ""
Write-Output "=== Windows Biometric Service ==="
$wbio = Get-Service -Name 'WbioSrvc' -ErrorAction SilentlyContinue
if ($null -eq $wbio) {
    Write-Output "WbioSrvc: Not found"
} else {
    $isRunning = ($wbio.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
    Write-Output "WbioSrvc: $($wbio.Status) (StartType: $($wbio.StartType), Running: $isRunning)"
}

Write-Output ""
Write-Output "=== Summary ==="
if ($topology.IrSensors.Count -eq 0 -or $topology.IrGroupIds.Count -eq 0) {
    Write-Output "STATUS: NOT_APPLICABLE"
    Write-Output "No Windows Hello IR sensor with FSSensorGroupId was detected on this machine."
} elseif ($topology.MatchedRgbEntries.Count -gt 0 -or $topology.SgDevApiDevices.Count -gt 0) {
    Write-Output "STATUS: LINKED"
    Write-Output "RGB camera is currently grouped with the IR sensor. Run Enable-WindowsHelloIROnly.ps1 as Administrator to decouple it."
} else {
    Write-Output "STATUS: ALREADY_SEPARATED"
    Write-Output "IR sensor is present and no RGB camera is linked to its Sensor Group. Windows Hello is configured for IR-only mode."
}
