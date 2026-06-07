[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = ".",

    [Parameter(Mandatory=$false)]
    [string]$DefaultVDom = "global",

    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive,

    [Parameter(Mandatory=$false)]
    [switch]$ExportPolicies,

    [Parameter(Mandatory=$false)]
    [string]$PolicyOutputDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Err {
    param([string]$Msg)
    Write-Host "[ERROR] $Msg" -ForegroundColor Red
}

function Write-Ok {
    param([string]$Msg)
    Write-Host "[OK] $Msg" -ForegroundColor Green
}

function Write-Info {
    param([string]$Msg)
    Write-Host "[INFO] $Msg" -ForegroundColor DarkGray
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " FortiGate VDom Splitter + Policy Export" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Validate input
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Err "Input file not found: $InputFile"
    exit 1
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    try {
        New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
        Write-Host "Created output directory: $OutputDirectory"
    }
    catch {
        Write-Err "Cannot create output directory: $OutputDirectory"
        exit 1
    }
}

if ($ExportPolicies) {
    if ([string]::IsNullOrWhiteSpace($PolicyOutputDirectory)) {
        $PolicyOutputDirectory = Join-Path $OutputDirectory "policies"
    }
    if (-not (Test-Path -LiteralPath $PolicyOutputDirectory)) {
        try {
            New-Item -ItemType Directory -Path $PolicyOutputDirectory -Force -ErrorAction Stop | Out-Null
            Write-Host "Created policy output directory: $PolicyOutputDirectory"
        }
        catch {
            Write-Err "Cannot create policy output directory: $PolicyOutputDirectory"
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Read the config
# ---------------------------------------------------------------------------
Write-Host "Reading: $InputFile"
$lines = [System.IO.File]::ReadAllLines($InputFile)
Write-Host ("Total lines: {0:N0}" -f $lines.Length)

# ---------------------------------------------------------------------------
# 3. Parse into VDOMs
#
# config ... end   → configDepth tracked for VDOM switching
# edit ... next    → does NOT affect configDepth
# edit at depth==1 inside config vdom → VDOM switch
# ---------------------------------------------------------------------------
$buffer      = @{}
$order       = @()
$currentVDom = $DefaultVDom
$inVdomBlock = $false
$configDepth = 0

$buffer[$DefaultVDom] = @(
    "! Lines outside any `config vdom` block"
    "!"
)

$i = 0
while ($i -lt $lines.Length) {
    $raw  = $lines[$i]
    $trim = $raw.Trim()

    if ($trim -eq "") {
        $buffer[$currentVDom] += $raw
        $i++
        continue
    }

    if (-not $inVdomBlock -and $trim -match '^config\s+vdom\s*$') {
        $inVdomBlock = $true
        $configDepth = 1
        $buffer[$currentVDom] += $raw
        $i++
        continue
    }

    if ($inVdomBlock -and $trim -match '^edit\s+"?([^"\s]+)"?\s*$' -and $configDepth -eq 1) {
        $currentVDom = $Matches[1]
        if (-not $buffer.ContainsKey($currentVDom)) {
            $buffer[$currentVDom] = @()
            $order += $currentVDom
        }
        $buffer[$currentVDom] += $raw
        $i++
        continue
    }

    if ($trim -match '^config\s+\S') {
        if ($inVdomBlock) { $configDepth++ }
    }

    if ($trim -match '^end\s*$') {
        if ($inVdomBlock -and $configDepth -gt 0) { $configDepth-- }
        if ($inVdomBlock -and $configDepth -eq 0) { $inVdomBlock = $false }
    }

    if (-not $buffer.ContainsKey($currentVDom)) {
        $buffer[$currentVDom] = @()
    }
    $buffer[$currentVDom] += $raw

    $i++
}

if ($buffer.ContainsKey($DefaultVDom) -and $buffer[$DefaultVDom].Count -gt 0) {
    $order = @($DefaultVDom) + ($order | Where-Object { $_ -ne $DefaultVDom })
}

# ---------------------------------------------------------------------------
# 4. Write VDOM cfg files (unchanged from previous)
# ---------------------------------------------------------------------------
function New-OutputPath {
    param([string]$Name, [string]$Extension = ".cfg")
    $s = $Name.Trim()
    $s = $s -replace '[/\\:\*\?"<>\|]', '_'
    $s = $s -replace '\s+', '_'
    $s = $s.Trim('_')
    if ($s -eq "") { $s = "_empty_" }
    return Join-Path $OutputDirectory ("vdom_{0}{1}" -f $s, $Extension)
}

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host " VDOM config files" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow

$writtenCfg = 0
foreach ($name in $order) {
    $content = $buffer[$name]
    if ($null -eq $content -or $content.Count -eq 0) { continue }

    $dest = New-OutputPath -Name $name -Extension ".cfg"
    if (Test-Path -LiteralPath $dest) {
        Write-Err "Refusing to overwrite: $dest"
        exit 1
    }

    try {
        [System.IO.File]::WriteAllLines($dest, $content, [System.Text.UTF8Encoding]::new($true))
    }
    catch {
        Write-Err "Write failed for $dest : $_"
        exit 1
    }

    Write-Host ("  '{0,-18}' => {1}  ({2} lines)" -f $name, (Split-Path -Leaf $dest), $content.Count) -ForegroundColor DarkGray
    $writtenCfg++
}

Write-Ok "Wrote $writtenCfg VDOM config file(s)"

# ---------------------------------------------------------------------------
# 5. Policy export (optional)
# ---------------------------------------------------------------------------
if (-not $ExportPolicies) {
    Write-Host ""
    Write-Host "NOTE: Policy export disabled. Pass -ExportPolicies to enable." -ForegroundColor DarkYellow

    if (-not $NonInteractive) {
        try {
            while ($true) {
                $ans = Read-Host "Open output directory in Explorer? (y/n)"
                if ($ans -match '^[yY]') { Start-Process explorer.exe $OutputDirectory; break }
                if ($ans -match '^[nN]') { break }
            }
        }
        catch {}
    }
    exit 0
}

function Convert-MultiValueLine {
    <#
    .SYNOPSIS
    Turns:  set foo "a" "b" "c"
    Into:   @{ foo = @("a","b","c") }
    Also handles: set bar "single_value"
    #>
    param([string]$Line)

    $trim = $Line.Trim()
    if ($trim -notmatch '^(set|config|edit|next|end)\s+\S') { return @{} }

    $parts = Get-PolicyKeyValuePair -Line $trim
    if ($parts.Count -eq 0) { return @{} }

    $key = $parts[0]
    $vals = @()
    for ($v = 1; $v -lt $parts.Count; $v++) {
        $vals += $parts[$v]
    }

    if ($vals.Count -eq 0) {
        return @{ $key = "" }
    }
    elseif ($vals.Count -eq 1) {
        return @{ $key = $vals[0] }
    }
    else {
        return @{ $key = $vals }
    }
}

function Get-PolicyKeyValuePair {
    param([string]$Line)
    $trim = $Line.Trim()
    if ($trim -match '^set\s+(\S+)\s+"?([^"]*)"?\s*$') {
        $key = $Matches[1]
        $val = $Matches[2]
        if ([string]::IsNullOrWhiteSpace($val)) { return @($key) }
        return @($key, $val)
    }
    if ($trim -match '^set\s+(\S+)\s+"(.+)"\s+"(.+)"') {
        $key = $Matches[1]
        return @($key, $Matches[2], $Matches[3])
    }
    # Fallback: split roughly on first whitespace after the keyword
    if ($trim -match '^(set)\s+(\S+)') {
        $key = $Matches[2]
        $rest = $trim.Substring($Matches[0].Length).Trim()
        $vals = @()
        if ($rest -match '^"([^"]+)"$') {
            return @($key, $Matches[1])
        }
        if ($rest -match '^(\S+)$') {
            return @($key, $Matches[1])
        }
    }
    return @()
}

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host " Policy export" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow

$allPolicies       = @()
$policiesPerVDom   = @{}
$warnNoPolicy      = @()

foreach ($name in $order) {
    $content = $buffer[$name]
    if ($null -eq $content -or $content.Count -eq 0) { continue }

    $found = $false
    $currentPolicy = $null

    foreach ($raw in $content) {
        $trim = $raw.Trim()

        if ($trim -match '^config\s+firewall\s+policy\s*$') {
            $found = $true
            continue
        }

        if (-not $found) { continue }

        if ($trim -match '^edit\s+"?([^"\s]+)"?\s*$') {
            # Save previous policy
            if ($null -ne $currentPolicy) {
                $currentPolicy.VDOM = $name
                $allPolicies += $currentPolicy
            }

            $currentPolicy = [ordered]@{
                VDOM      = $name
                PolicyId  = -1
                Name      = ""
                SrcIntf   = @()
                DstIntf   = @()
                SrcAddr   = @()
                DstAddr   = @()
                Service   = @()
                Action    = ""
                Nat       = ""
                Schedule  = ""
                LogTraffic = ""
                UUID      = ""
                RawLines  = 0
            }

            # Try parse ID
            $idStr = $Matches[1]
            if ($idStr -match '^\d+$') {
                $currentPolicy.PolicyId = [long]$idStr
            }
            else {
                $currentPolicy.Name = $idStr
            }
            continue
        }

        if ($trim -eq "next") {
            if ($null -ne $currentPolicy) {
                $currentPolicy.VDOM = $name
                $allPolicies += $currentPolicy
                $currentPolicy = $null
            }
            continue
        }

        if ($trim -eq "end") {
            if ($null -ne $currentPolicy) {
                $currentPolicy.VDOM = $name
                $allPolicies += $currentPolicy
                $currentPolicy = $null
            }
            $found = $false
            continue
        }

        if ($null -ne $currentPolicy) {
            $currentPolicy.RawLines++
            $kv = Convert-MultiValueLine -Line $trim

            foreach ($k in $kv.Keys) {
                $v = $kv[$k]
                switch ($k) {
                    "name" { $currentPolicy.Name = $v }
                    "uuid" { $currentPolicy.UUID = $v }
                    "action" { $currentPolicy.Action = $v }
                    "nat" { $currentPolicy.Nat = $v }
                    "schedule" { $currentPolicy.Schedule = $v }
                    "logtraffic" { $currentPolicy.LogTraffic = $v }
                    "srcintf" {
                        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                            $currentPolicy.SrcIntf += $v
                        }
                        else {
                            $currentPolicy.SrcIntf += $v
                        }
                    }
                    "dstintf" {
                        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                            $currentPolicy.DstIntf += $v
                        }
                        else {
                            $currentPolicy.DstIntf += $v
                        }
                    }
                    "srcaddr" {
                        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                            $currentPolicy.SrcAddr += $v
                        }
                        else {
                            $currentPolicy.SrcAddr += $v
                        }
                    }
                    "dstaddr" {
                        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                            $currentPolicy.DstAddr += $v
                        }
                        else {
                            $currentPolicy.DstAddr += $v
                        }
                    }
                    "service" {
                        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
                            $currentPolicy.Service += @($v)
                        }
                        else {
                            $currentPolicy.Service += $v
                        }
                    }
                }
            }
        }
    }

    if ($found) {
        $warnNoPolicy += $name
    }
}

# Flatten arrays to delimited strings for storage
function Join-Array {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return ($Value | ForEach-Object { $_ }) -join ", "
    }
    return [string]$Value
}

# 6. Export policies per VDOM and aggregated
$allOutput = @()
$writtenPol = 0

foreach ($name in $order) {
    $list = $allPolicies | Where-Object { $_.VDOM -eq $name } | Sort-Object { $_.PolicyId }
    if ($null -eq $list -or $list.Count -eq 0) {
        Write-Info "  '$name' → 0 policies"
        continue
    }

    $policiesPerVDom[$name] = $list

    # JSON per VDOM
    $destJson = Join-Path $PolicyOutputDirectory ("policies_{0}.json" -f ($name -replace '[/\\:\*\?"<>\|\s]+','_'))
    $destCsv  = Join-Path $PolicyOutputDirectory ("policies_{0}.csv"  -f ($name -replace '[/\\:\*\?"<>\|\s]+','_'))

    $out = foreach ($p in $list) {
        [ordered]@{
            VDom       = $p.VDOM
            PolicyId   = $p.PolicyId
            Name       = $p.Name
            SrcIntf    = Join-Array $p.SrcIntf
            DstIntf    = Join-Array $p.DstIntf
            SrcAddr    = Join-Array $p.SrcAddr
            DstAddr    = Join-Array $p.DstAddr
            Service    = Join-Array $p.Service
            Action     = $p.Action
            Nat        = $p.Nat
            Schedule   = $p.Schedule
            LogTraffic = $p.LogTraffic
            UUID       = $p.UUID
        }
    }

    try {
        $out | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $destJson -Encoding UTF8
        $out | Export-Csv -LiteralPath $destCsv -NoTypeInformation -Encoding UTF8
        $allOutput += $out
        $writtenPol++
    }
    catch {
        Write-Err "Failed writing policy files for VDOM '$name': $_"
    }

    Write-Host ("  '{0,-18}' => {1,4} policies  ({2}, {3})" -f $name, $list.Count, (Split-Path -Leaf $destJson), (Split-Path -Leaf $destCsv)) -ForegroundColor DarkGray
}

# Aggregated exports
if ($allOutput.Count -gt 0) {
    $aggJson = Join-Path $PolicyOutputDirectory "policies_all.json"
    $aggCsv  = Join-Path $PolicyOutputDirectory "policies_all.csv"

    try {
        $allOutput | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $aggJson -Encoding UTF8
        $allOutput | Export-Csv -LiteralPath $aggCsv -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-Ok ("Aggregated exports: {0} and {1}" -f (Split-Path -Leaf $aggJson), (Split-Path -Leaf $aggCsv))
    }
    catch {
        Write-Err "Failed writing aggregated policy exports: $_"
    }
}
else {
    Write-Host ""
    Write-Host "No firewall policies found." -ForegroundColor DarkYellow
}

Write-Host ""
Write-Ok ("Policy export complete: {0} policy group(s), {1} total policy rules" -f $writtenPol, $allOutput.Count)

Write-Host ""
Write-Host "Example query (PowerShell):" -ForegroundColor Cyan
Write-Host "  `$all = Import-Csv 'D:\\fortigate-out\\policies\\policies_all.csv'" -ForegroundColor DarkGray
Write-Host '  $all | Where-Object Action -eq "accept" | Format-Table VDom, PolicyId, Name, SrcAddr, DstAddr, Service' -ForegroundColor DarkGray
Write-Host '  $all | Where-Object Nat -eq "enable" | Export-Csv nat-policies.csv -NoType' -ForegroundColor DarkGray
Write-Host '  $all | Where-Object { $_.SrcAddr -match "192\.168" } | Select-Object VDom, PolicyId, Name' -ForegroundColor DarkGray

Write-Host ""
if (-not $NonInteractive) {
    try {
        while ($true) {
            $ans = Read-Host "Open output directory in Explorer? (y/n)"
            if ($ans -match '^[yY]') { Start-Process explorer.exe $OutputDirectory; break }
            if ($ans -match '^[nN]') { break }
        }
    }
    catch {}
}
