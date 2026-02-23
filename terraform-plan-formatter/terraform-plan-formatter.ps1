# Terraform Plan Formatter (PowerShell version)
# Reads Terraform plan log output and emits GitHub Actions ##[group] / ##[endgroup]
# with leading timestamp and ANSI codes stripped for readability in CI.
#
# Structure: Terraform refresh/init and footer notes are foldable; the actual
# plan (resource changes) is shown in full so you can focus on what matters.

param(
    [Parameter(Position = 0)]
    [string]$LogFile = ""
)

if ($args.Count -gt 1) {
    Write-Error "Usage: $MyInvocation.MyCommand.Name [logfile]"
    exit 1
}

$InputPath = $LogFile

# Set to $true to strip leading ISO timestamps for readability
$StripIsoTimestamp = $true

function Remove-AnsiEscapes {
    param([string]$s)
    $esc = [char]0x1b
    # Strip ESC [ ... m sequences (standard ANSI)
    $s = $s -replace ([regex]::Escape($esc) + '\[[\d;]*m'), ''
    # Strip [ ... m when stored as literal text (e.g. in pipeline logs)
    $s = $s -replace '\[?\[[\d;]*m', ''
    return $s
}

function Add-PlanColor {
    param([string]$line)

    $esc = [char]0x1b
    $reset  = "${esc}[0m"
    $green  = "${esc}[32m"
    $red    = "${esc}[31m"
    $yellow = "${esc}[33m"
    $cyan   = "${esc}[36m"
    $bold   = "${esc}[1m"

    if ($line -match '^\s*#') {
        if ($line -match 'will be created')        { return "$green$line$reset" }
        if ($line -match 'will be destroyed')      { return "$red$line$reset" }
        if ($line -match 'will be updated')        { return "$yellow$line$reset" }
        if ($line -match 'must be replaced')       { return "$red$line$reset" }
        if ($line -match 'will be read')           { return "$cyan$line$reset" }
        return $line
    }

    if ($line -match '^Plan:') {
        $result = $line
        if ($result -match '(\d+ to add)')     { $result = $result.Replace($Matches[0], "${green}$($Matches[0])${reset}") }
        if ($result -match '(\d+ to change)')  { $result = $result.Replace($Matches[0], "${yellow}$($Matches[0])${reset}") }
        if ($result -match '(\d+ to destroy)') { $result = $result.Replace($Matches[0], "${red}$($Matches[0])${reset}") }
        return "${bold}${result}${reset}"
    }

    if ($line -match 'No changes\.')               { return "${green}${line}${reset}" }

    if ($line -match '^\s*-/\+')                   { return "$red$line$reset" }
    if ($line -match '^\s*\+/-')                   { return "$yellow$line$reset" }
    if ($line -match '^\s*\+')                     { return "$green$line$reset" }
    if ($line -match '^\s*~')                      { return "$yellow$line$reset" }
    if ($line -match '^\s*-')                      { return "$red$line$reset" }
    if ($line -match '^\s*<=')                     { return "$cyan$line$reset" }

    return $line
}

function Get-CleanedLine {
    param([string]$raw)
    if ($StripIsoTimestamp) {
        $raw = $raw -replace '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s*', ''
    }
    $out = Remove-AnsiEscapes $raw
    # Strip "HH:MM:SS.mmm STDOUT " prefix (from Azure DevOps / script output)
    $out = $out -replace '^\d{1,2}:\d{2}:\d{2}\.\d+\s+STDOUT\s+', ''
    return $out
}

# Section states: preamble (foldable), plan (visible), footer (foldable)
$state = 'preamble'
$pendingLines = [System.Collections.Generic.List[string]]::new()
$sectionCount = 0

function Get-SectionTitle {
    param([System.Collections.Generic.List[string]]$lines)
    foreach ($l in $lines) {
        $trimmed = $l.Trim()
        if ($trimmed -ne '' -and $trimmed -notmatch '^=+$') {
            if ($trimmed.Length -gt 80) { $trimmed = $trimmed.Substring(0, 77) + '...' }
            return $trimmed
        }
    }
    return $null
}

function Flush-Section {
    param([string]$FallbackTitle)
    if ($pendingLines.Count -eq 0) { return }
    $title = Get-SectionTitle $pendingLines
    if (-not $title) { $title = $FallbackTitle }
    $script:sectionCount++
    Write-Host "##[group]$title"
    foreach ($l in $pendingLines) { Write-Host $l }
    Write-Host '##[endgroup]'
    $pendingLines.Clear()
}

function Process-Line {
    param([string]$raw)
    $cleaned = Get-CleanedLine $raw

    # Split preamble / footer into smaller groups at ====... separator lines
    if (($state -eq 'preamble' -or $state -eq 'footer') -and $cleaned -match '^\s*={10,}\s*$') {
        [void]$pendingLines.Add($cleaned)
        $fallback = if ($state -eq 'preamble') { 'Terraform Setup' } else { 'Notes' }
        Flush-Section -FallbackTitle $fallback
        return
    }

    # Detect plan start (real changes section) - only when still in preamble
    if ($state -eq 'preamble' -and ($cleaned -match 'Terraform used the selected providers|Terraform will perform the following actions')) {
        Flush-Section -FallbackTitle 'Terraform Init'
        $script:state = 'plan'
    }

    # Detect plan end (summary or no-changes)
    if ($state -eq 'plan' -and ($cleaned -match 'Plan:.*(?:to add|to change|to destroy)' -or $cleaned -match 'No changes\. Your infrastructure')) {
        Write-Host (Add-PlanColor $cleaned)
        $script:state = 'footer'
        return
    }

    switch ($state) {
        'preamble' { [void]$pendingLines.Add($cleaned) }
        'plan'    { Write-Host (Add-PlanColor $cleaned) }
        'footer'  { [void]$pendingLines.Add($cleaned) }
    }
}

if ($InputPath) {
    if (-not (Test-Path -LiteralPath $InputPath)) {
        Write-Error "File not found: $InputPath"
        exit 1
    }
    Get-Content -LiteralPath $InputPath | ForEach-Object { Process-Line $_ }
} else {
    $input | ForEach-Object { Process-Line $_ }
}

if ($state -eq 'preamble') { Flush-Section -FallbackTitle 'Terraform Init' }
elseif ($state -eq 'footer') { Flush-Section -FallbackTitle 'Notes & Warnings' }
