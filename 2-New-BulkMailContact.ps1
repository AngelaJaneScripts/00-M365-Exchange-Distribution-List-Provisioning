<#
.SYNOPSIS
    Stage 2 of 3: makes sure every validated address exists as a recipient in
    Exchange Online, creating mail contacts for external addresses that don't.

.DESCRIPTION
    Takes the "valid" CSV from stage 1. Before creating anything, it pulls
    every recipient address in the tenant once and builds a lookup table, so
    8,000+ rows means one bulk query rather than 8,000 individual lookups.

    For each row:
      - address already belongs to a recipient (staff mailbox, existing
        contact, group)  -> resolved, nothing created
      - address unknown  -> New-MailContact (optionally hidden from the GAL)
      - creation fails   -> logged with the error, run continues

    Outputs a "resolved" CSV with each address's PrimarySmtpAddress for
    stage 3, plus a full action log.

    Supports -WhatIf. Always run it with -WhatIf first.

.PARAMETER InputPath
    The 1-valid-*.csv file from stage 1.

.PARAMETER HideFromAddressLists
    Hide newly created contacts from the Global Address List. Useful when the
    contacts exist only to receive mail through a distribution list.

.EXAMPLE
    Connect-ExchangeOnline
    ./2-New-BulkMailContact.ps1 -InputPath ../output/1-valid-20261026.csv -HideFromAddressLists -WhatIf

.NOTES
    Requires: ExchangeOnlineManagement module, an active Connect-ExchangeOnline
    session, and a role that can create mail contacts (for example Recipient
    Management, or Mail Recipient Creation). Use the least privileged role
    that works rather than Global Administrator.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InputPath,

    [string]$OutputFolder = './output',

    [switch]$HideFromAddressLists
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-EXORecipient -ErrorAction SilentlyContinue)) {
    throw 'Exchange Online cmdlets not found. Install ExchangeOnlineManagement and run Connect-ExchangeOnline first.'
}

$rows = @(Import-Csv -Path $InputPath)
if ($rows.Count -eq 0) { throw "Input file '$InputPath' has no rows." }

# --- One bulk query: every SMTP address in the tenant -> its PrimarySmtpAddress
Write-Host 'Building recipient lookup (one query for the whole tenant)...' -ForegroundColor Cyan
$lookup = @{}   # PowerShell hashtables are case-insensitive by default
Get-EXORecipient -ResultSize Unlimited -Properties EmailAddresses | ForEach-Object {
    $primary = "$($_.PrimarySmtpAddress)".ToLowerInvariant()
    foreach ($addr in $_.EmailAddresses) {
        if ($addr -like 'smtp:*') { $lookup[$addr.Substring(5).ToLowerInvariant()] = $primary }
    }
    $lookup[$primary] = $primary
}
Write-Host ("  {0} addresses indexed" -f $lookup.Count)

$log      = [System.Collections.Generic.List[object]]::new()
$resolved = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($row in $rows) {
    $i++
    Write-Progress -Activity 'Resolving recipients' -Status $row.Email -PercentComplete (($i / $rows.Count) * 100)
    $email = $row.Email.ToLowerInvariant()

    if ($lookup.ContainsKey($email)) {
        $resolved.Add([pscustomobject]@{ Email = $email; PrimarySmtpAddress = $lookup[$email] })
        $log.Add([pscustomobject]@{ Email = $email; Action = 'Existing recipient'; Detail = $lookup[$email] })
        continue
    }

    # Name must be unique and is capped at 64 characters; the address is
    # unique by definition, so use it.
    $name = if ($email.Length -le 64) { $email } else { $email.Substring(0, 64) }

    if ($PSCmdlet.ShouldProcess($email, 'New-MailContact')) {
        try {
            $null = New-MailContact -Name $name -DisplayName $row.DisplayName `
                        -FirstName $row.FirstName -LastName $row.LastName `
                        -ExternalEmailAddress $email
            if ($HideFromAddressLists) {
                Set-MailContact -Identity $email -HiddenFromAddressListsEnabled $true
            }
            $lookup[$email] = $email
            $resolved.Add([pscustomobject]@{ Email = $email; PrimarySmtpAddress = $email })
            $log.Add([pscustomobject]@{ Email = $email; Action = 'Contact created'; Detail = '' })
        }
        catch {
            $log.Add([pscustomobject]@{ Email = $email; Action = 'FAILED'; Detail = $_.Exception.Message })
        }
    }
    else {
        $log.Add([pscustomobject]@{ Email = $email; Action = 'WhatIf: would create contact'; Detail = '' })
    }
}
Write-Progress -Activity 'Resolving recipients' -Completed

New-Item -ItemType Directory -Path $OutputFolder -Force -WhatIf:$false | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resolvedPath = Join-Path $OutputFolder "2-resolved-$stamp.csv"
$logPath      = Join-Path $OutputFolder "2-log-$stamp.csv"
$resolved | Export-Csv -Path $resolvedPath -NoTypeInformation -WhatIf:$false
$log      | Export-Csv -Path $logPath      -NoTypeInformation -WhatIf:$false

Write-Host ''
Write-Host 'Stage 2 complete: recipients' -ForegroundColor Cyan
$log | Group-Object Action | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-30} {1}" -f $_.Name, $_.Count) }
Write-Host "  Resolved file : $resolvedPath"
Write-Host "  Action log    : $logPath"
