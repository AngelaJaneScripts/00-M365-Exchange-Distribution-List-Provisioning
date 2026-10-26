<#
.SYNOPSIS
    Stage 1 of 3: validates and cleans a source list of email addresses before
    anything touches Exchange Online.

.DESCRIPTION
    Reads a CSV with Email, FirstName and LastName columns and checks every row:
      - required columns are present
      - the email is not blank and is a plausible address
      - duplicates are removed (case-insensitive, after trimming whitespace)
      - a display name can be built

    Clean rows go to a "valid" CSV for stage 2. Every rejected row goes to a
    "rejected" CSV with the reason, so nothing disappears silently.

    This stage runs entirely offline. No Exchange connection is needed.

.PARAMETER InputPath
    Path to the source CSV.

.PARAMETER OutputFolder
    Folder for the valid/rejected CSVs. Created if it doesn't exist.

.EXAMPLE
    ./1-Test-ContactList.ps1 -InputPath ../sample/contacts-sample.csv -OutputFolder ../output
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InputPath,

    [string]$OutputFolder = './output'
)

$ErrorActionPreference = 'Stop'

# A pragmatic check, not full RFC 5322. It catches the errors that actually
# turn up in HR exports: spaces, missing @, missing domain, double dots.
$emailPattern = '^[A-Za-z0-9._%+''-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$'

$rows = @(Import-Csv -Path $InputPath)
if ($rows.Count -eq 0) { throw "Input file '$InputPath' has no data rows." }

$required = 'Email', 'FirstName', 'LastName'
$missing  = $required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) { throw "Input file is missing required column(s): $($missing -join ', ')" }

$seen     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$valid    = [System.Collections.Generic.List[object]]::new()
$rejected = [System.Collections.Generic.List[object]]::new()
$line     = 1   # header is line 1

foreach ($row in $rows) {
    $line++
    $email = "$($row.Email)".Trim()
    $first = "$($row.FirstName)".Trim()
    $last  = "$($row.LastName)".Trim()

    $reason = $null
    if     ([string]::IsNullOrWhiteSpace($email)) { $reason = 'Blank email' }
    elseif ($email -notmatch $emailPattern)       { $reason = 'Invalid email format' }
    elseif ($email -match '\.\.')                 { $reason = 'Invalid email format (consecutive dots)' }
    elseif (-not $seen.Add($email))               { $reason = 'Duplicate email' }

    if ($reason) {
        $rejected.Add([pscustomobject]@{
            SourceLine = $line; Email = $email; FirstName = $first; LastName = $last; Reason = $reason
        })
        continue
    }

    $displayName = ("$first $last").Trim()
    if (-not $displayName) { $displayName = $email }

    $valid.Add([pscustomobject]@{
        Email = $email.ToLowerInvariant(); FirstName = $first; LastName = $last; DisplayName = $displayName
    })
}

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$validPath    = Join-Path $OutputFolder "1-valid-$stamp.csv"
$rejectedPath = Join-Path $OutputFolder "1-rejected-$stamp.csv"

$valid    | Export-Csv -Path $validPath    -NoTypeInformation
$rejected | Export-Csv -Path $rejectedPath -NoTypeInformation

Write-Host ''
Write-Host 'Stage 1 complete: validation' -ForegroundColor Cyan
Write-Host ("  Rows read : {0}" -f $rows.Count)
Write-Host ("  Valid     : {0}" -f $valid.Count) -ForegroundColor Green
Write-Host ("  Rejected  : {0}" -f $rejected.Count) -ForegroundColor ($(if ($rejected.Count) { 'Yellow' } else { 'Green' }))
$rejected | Group-Object Reason | ForEach-Object { Write-Host ("    - {0}: {1}" -f $_.Name, $_.Count) }
Write-Host "  Valid file    : $validPath"
Write-Host "  Rejected file : $rejectedPath"
