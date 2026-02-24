# Terraform Plan Formatter (PowerShell version)
# Wraps Terraform plan log output in Azure DevOps ##[group] / ##[endgroup]
# collapsible sections. Lines are passed through verbatim — nothing is
# modified, only group markers are injected.
#
# Structure: Preamble (refresh/init) and footer (notes/warnings) are wrapped
# in collapsible sections (split at ====... separators). The plan itself
# (resource changes) is emitted as-is so you can focus on what matters.

param(
    [Parameter(Position = 0)]
    [string]$PathOrFullPath = "",
    [Parameter(Position = 1)]
    [string]$FileName = ""
)

if ($args.Count -gt 0) {
    Write-Error "Usage: $($MyInvocation.MyCommand.Name) [<full-path-and-filename>] | [<path> <filename>]"
    exit 1
}

# One arg = full path+filename; two args = path + filename
if ($FileName) {
    $InputPath = Join-Path -Path $PathOrFullPath -ChildPath $FileName
} else {
    $InputPath = $PathOrFullPath
}

# Produce an ANSI/timestamp-free copy of a line for pattern matching only.
# This is never used for output — only to detect state transitions reliably.
function Get-MatchText {
    param([string]$s)
    $s = $s -replace '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s*', ''
    $s = $s -replace '^\d{1,2}:\d{2}:\d{2}\.\d+\s+STDOUT\s+', ''
    $esc = [char]0x1b
    $s = $s -replace ([regex]::Escape($esc) + '\[[\d;]*m'), ''
    $s = $s -replace '\[?\[[\d;]*m', ''
    return $s
}

$state = 'preamble'
$pendingLines = [System.Collections.Generic.List[string]]::new()

function Get-SectionTitle {
    param([System.Collections.Generic.List[string]]$lines)
    foreach ($l in $lines) {
        $text = (Get-MatchText $l).Trim()
        if ($text -ne '' -and $text -notmatch '^=+$') {
            if ($text.Length -gt 80) { $text = $text.Substring(0, 77) + '...' }
            return $text
        }
    }
    return $null
}

function Flush-Section {
    param([string]$FallbackTitle)
    if ($pendingLines.Count -eq 0) { return }
    $title = Get-SectionTitle $pendingLines
    if (-not $title) { $title = $FallbackTitle }
    Write-Host "##[group]$title"
    foreach ($l in $pendingLines) { Write-Host $l }
    Write-Host '##[endgroup]'
    $pendingLines.Clear()
}

function Process-Line {
    param([string]$raw)
    $match = Get-MatchText $raw

    # Split preamble / footer into smaller groups at ====... separator lines
    if (($state -eq 'preamble' -or $state -eq 'footer') -and $match -match '^\s*={10,}\s*$') {
        [void]$pendingLines.Add($raw)
        $fallback = if ($state -eq 'preamble') { 'Terraform Setup' } else { 'Notes' }
        Flush-Section -FallbackTitle $fallback
        return
    }

    # Detect plan start — only when still in preamble
    if ($state -eq 'preamble' -and ($match -match 'Terraform used the selected providers|Terraform will perform the following actions')) {
        Flush-Section -FallbackTitle 'Terraform Init'
        $script:state = 'plan'
    }

    # Detect plan end (summary or no-changes)
    if ($state -eq 'plan' -and ($match -match 'Plan:.*(?:to add|to change|to destroy)' -or $match -match 'No changes\. Your infrastructure')) {
        Write-Host $raw
        $script:state = 'footer'
        return
    }

    switch ($state) {
        'preamble' { [void]$pendingLines.Add($raw) }
        'plan'     { Write-Host $raw }
        'footer'   { [void]$pendingLines.Add($raw) }
    }
}

if ($InputPath) {
    if (-not (Test-Path -LiteralPath $InputPath)) {
        Write-Error "File not found: $InputPath"
        exit 1
    }
    # Reject ZIP/artifact bundles — this script expects the terraform plan LOG (stdout), not the .plan artifact
    $fs = [System.IO.File]::OpenRead($InputPath)
    try {
        $header = New-Object byte[] 2
        $null = $fs.Read($header, 0, 2)
    } finally { $fs.Dispose() }
    if ($header[0] -eq 0x50 -and $header[1] -eq 0x4B) {
        Write-Error @"
This file appears to be a ZIP archive (pipeline artifact), not the Terraform plan log.

This formatter expects the TEXT output from 'terraform plan' (the log you see in the browser),
not the binary artifact (.plan, tfstate, etc.).

Fix: Pass the plan log file. Capture it in your pipeline, e.g.:
  terraform plan -out=tfplan 2>&1 | Tee-Object -FilePath plan.log
  .\terraform-plan-formatter.ps1 plan.log
"@
        exit 1
    }
    # Support text and binary-coded files: StreamReader auto-detects BOM (UTF-8, UTF-16, etc.)
    # Fallback: if encoding errors occur (invalid bytes), decode with replacement fallback
    try {
        $reader = [System.IO.StreamReader]::new($InputPath, [System.Text.Encoding]::UTF8, $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                Process-Line $line
            }
        } finally {
            $reader.Dispose()
        }
    } catch [System.Text.DecoderFallbackException] {
        # Invalid byte sequences — read as bytes and decode with replacement fallback
        $bytes = [System.IO.File]::ReadAllBytes($InputPath)
        $enc = [System.Text.Encoding]::UTF8
        $offset = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $enc = [System.Text.Encoding]::UTF8
            $offset = 3
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $enc = [System.Text.Encoding]::Unicode
            $offset = 2
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $enc = [System.Text.Encoding]::BigEndianUnicode
            $offset = 2
        }
        $enc = [System.Text.Encoding]::GetEncoding($enc.CodePage, $enc.EncoderFallback, [System.Text.DecoderReplacementFallback]::new('�'))
        $text = $enc.GetString($bytes, $offset, $bytes.Length - $offset)
        $text -split "`r?`n" | ForEach-Object { Process-Line $_ }
    }
} else {
    $input | ForEach-Object { Process-Line $_ }
}

if ($state -eq 'preamble') { Flush-Section -FallbackTitle 'Terraform Init' }
elseif ($state -eq 'footer') { Flush-Section -FallbackTitle 'Notes & Warnings' }
