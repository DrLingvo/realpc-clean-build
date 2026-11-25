#requires -Version 5.1
<#
.SYNOPSIS
Collects Windows guest evidence without turning missing probes into a pass.

.PARAMETER OutputDirectory
Directory for raw JSON, text, exit codes, and summary.json.

.PARAMETER AlKhaserPath
Optional path to al-khaser.exe. Move the mouse and use the keyboard while it runs.

.PARAMETER CpuIdProbePath
Optional probe that reports at least CPUID.1 and hypervisor leaf 0x40000000.

.PARAMETER RdMsrProbePath
Optional kernel-backed probe for RDMSR 0x4b564d00 through 0x4b564d08.
A user-mode instruction substitute is not valid RDMSR evidence. Every read must
report the value or #GP; do not use a probe that fabricates either result.

.PARAMETER PmuProbePath
Optional probe that measures real cycles and instructions under two workloads.
Windows performance counters are not accepted as a substitute.

.PARAMETER AcpiDumpPath
Optional acpidump executable. Its complete textual output is retained.

.PARAMETER AcpiTableDirectory
Optional directory containing previously dumped ACPI tables to scan recursively.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Get-Location) ("realpc-audit-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),
    [string]$AlKhaserPath = "",
    [string]$CpuIdProbePath = "",
    [string]$RdMsrProbePath = "",
    [string]$PmuProbePath = "",
    [string]$AcpiDumpPath = "",
    [string]$AcpiTableDirectory = "",
    [ValidateRange(30, 3600)]
    [int]$ProbeTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$ErrorLog = Join-Path $OutputDirectory "collection-errors.log"

function Write-Json {
    param([string]$Path, $Object)
    ConvertTo-Json -InputObject $Object -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
    } catch {
        $message = "${Name}: $($_.Exception.Message)"
        Add-Content -Path $ErrorLog -Value $message
        Write-Warning $message
    }
}

function Invoke-ExternalProbe {
    param([string]$Name, [string]$Path)
    $stdoutPath = Join-Path $OutputDirectory ($Name + ".stdout.txt")
    $stderrPath = Join-Path $OutputDirectory ($Name + ".stderr.txt")
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{
            status = "NOT_TESTED"
            reason = "No probe was supplied; absence is not a pass"
            stdout = $stdoutPath
            stderr = $stderrPath
            exit_code = $null
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{
            status = "ERROR"
            reason = "Probe does not exist: $Path"
            stdout = $stdoutPath
            stderr = $stderrPath
            exit_code = $null
        }
    }

    $process = $null
    $stdout = ""
    $stderr = ""
    $status = "ERROR"
    $reason = ""
    $exitCode = $null
    try {
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = (Resolve-Path -LiteralPath $Path).Path
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) {
            throw "Process did not start"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($ProbeTimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            $status = "TIMEOUT"
            $reason = "Probe exceeded $ProbeTimeoutSeconds seconds"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
        if ($status -ne "TIMEOUT") {
            $status = if ($exitCode -eq 0) { "COLLECTED" } else { "ERROR" }
            $reason = if ($exitCode -eq 0) { "Probe completed; inspect its raw evidence" } else { "Probe returned a nonzero exit code" }
        }
    } catch {
        $status = "ERROR"
        $reason = $_.Exception.Message
    } finally {
        Set-Content -Path $stdoutPath -Value $stdout -Encoding UTF8
        Set-Content -Path $stderrPath -Value $stderr -Encoding UTF8
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
    return [ordered]@{
        status = $status
        reason = $reason
        stdout = $stdoutPath
        stderr = $stderrPath
        exit_code = $exitCode
    }
}

function Get-StringEvidence {
    param([string[]]$Files)
    $hits = @()
    $stringDirectory = Join-Path $OutputDirectory "acpi-strings"
    New-Item -ItemType Directory -Path $stringDirectory -Force | Out-Null
    $pattern = "QEMU|BOCHS|BXPC|FWCF|WAET|VMGENID|VBOX|VMWARE|VIRTUAL"
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            continue
        }
        $item = Get-Item -LiteralPath $file
        if ($item.Length -gt 67108864) {
            Add-Content -Path $ErrorLog -Value "ACPI string scan skipped a file over 64 MiB: $file"
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
        $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
        $strings = @([regex]::Matches($ascii, "[\x20-\x7E]{4,}") | ForEach-Object { $_.Value })
        $strings += @([regex]::Matches($unicode, "[\x20-\x7E]{4,}") | ForEach-Object { $_.Value })
        $safeName = ($item.Name -replace "[^A-Za-z0-9_.-]", "_")
        Set-Content -Path (Join-Path $stringDirectory ($safeName + ".txt")) -Value $strings -Encoding UTF8
        $hits += @($strings | Where-Object { $_ -match $pattern } | ForEach-Object {
            [ordered]@{ file = $item.FullName; value = $_ }
        })
    }
    return $hits
}

$identity = [ordered]@{}
Invoke-Step "system identity" {
    $identity["operating_system"] = Get-CimInstance Win32_OperatingSystem
    $identity["computer_system"] = Get-CimInstance Win32_ComputerSystem
    $identity["bios"] = Get-CimInstance Win32_BIOS
    $identity["baseboard"] = Get-CimInstance Win32_BaseBoard
    $identity["processor"] = Get-CimInstance Win32_Processor
    Write-Json (Join-Path $OutputDirectory "system-identity.json") $identity
}

$pnpHits = @()
Invoke-Step "PNP devices" {
    $devices = @(Get-CimInstance Win32_PnPEntity)
    Write-Json (Join-Path $OutputDirectory "pnp-devices.json") $devices
    $pnpHits = @($devices | Where-Object { $_.DeviceID -match "VEN_1B36" })
    Write-Json (Join-Path $OutputDirectory "pnp-ven-1b36.json") $pnpHits
}

Invoke-Step "memory WMI and CIM" {
    foreach ($class in @("Win32_PhysicalMemory", "Win32_PhysicalMemoryArray", "Win32_MemoryDevice", "Win32_MemoryArray", "Win32_MemoryDeviceArray")) {
        $items = @(Get-CimInstance -ClassName $class)
        Write-Json (Join-Path $OutputDirectory ($class + ".json")) $items
    }
}

$serviceDriverHits = @()
Invoke-Step "services and drivers" {
    $services = @(Get-CimInstance Win32_Service)
    $drivers = @(Get-CimInstance Win32_SystemDriver)
    Write-Json (Join-Path $OutputDirectory "services.json") $services
    Write-Json (Join-Path $OutputDirectory "drivers.json") $drivers
    $pattern = "QEMU|VIRTIO|SPICE|BALLOON|VBOX|VMWARE|GUEST.AGENT"
    $serviceDriverHits = @($services + $drivers | Where-Object {
        ($_.Name -match $pattern) -or ($_.DisplayName -match $pattern) -or ($_.PathName -match $pattern)
    })
    Write-Json (Join-Path $OutputDirectory "virtualization-service-driver-hits.json") $serviceDriverHits
}

$acpiResult = Invoke-ExternalProbe -Name "acpidump" -Path $AcpiDumpPath
$acpiHits = @()
Invoke-Step "ACPI strings" {
    $files = @()
    if (-not [string]::IsNullOrWhiteSpace($AcpiTableDirectory)) {
        $files += @(Get-ChildItem -LiteralPath $AcpiTableDirectory -Recurse -File | ForEach-Object { $_.FullName })
    }
    if (Test-Path -LiteralPath $acpiResult.stdout -PathType Leaf) {
        $files += $acpiResult.stdout
    }
    $acpiHits = @(Get-StringEvidence -Files $files)
    Write-Json (Join-Path $OutputDirectory "acpi-string-hits.json") $acpiHits
}

$cpuIdResult = Invoke-ExternalProbe -Name "cpuid" -Path $CpuIdProbePath
$rdmsrResult = Invoke-ExternalProbe -Name "rdmsr-kvm-range" -Path $RdMsrProbePath
$pmuResult = Invoke-ExternalProbe -Name "pmu" -Path $PmuProbePath

if (-not [string]::IsNullOrWhiteSpace($AlKhaserPath)) {
    Write-Host "Al-Khaser is starting. Move the real mouse and use the real keyboard during the test."
}
$alKhaserResult = Invoke-ExternalProbe -Name "al-khaser-full" -Path $AlKhaserPath

$probeResults = @($acpiResult, $cpuIdResult, $rdmsrResult, $pmuResult, $alKhaserResult)
$summary = [ordered]@{
    schema = 1
    collected_utc = (Get-Date).ToUniversalTime().ToString("o")
    output_directory = $OutputDirectory
    overall = if (@($probeResults | Where-Object { $_.status -ne "COLLECTED" }).Count -eq 0) { "COLLECTED" } else { "PARTIAL" }
    pnp_ven_1b36 = [ordered]@{
        status = if ($pnpHits.Count -eq 0) { "NOT_DETECTED" } else { "DETECTED" }
        count = $pnpHits.Count
    }
    virtualization_service_driver_hits = $serviceDriverHits.Count
    acpi = [ordered]@{ probe = $acpiResult; string_hit_count = $acpiHits.Count }
    cpuid = $cpuIdResult
    rdmsr_kvm_range = $rdmsrResult
    pmu = $pmuResult
    al_khaser = $alKhaserResult
    input_requirement = "Real mouse movement and keyboard input are required during Al-Khaser"
    interpretation = "COLLECTED is not CLOSED. NOT_TESTED, ERROR, and TIMEOUT are never passes. Review raw evidence and DETECTION-MATRIX.md."
}
Write-Json (Join-Path $OutputDirectory "summary.json") $summary
Write-Host "Audit evidence written to $OutputDirectory"
Write-Host "Overall collection status: $($summary.overall). Missing or failed probes are not passes."
