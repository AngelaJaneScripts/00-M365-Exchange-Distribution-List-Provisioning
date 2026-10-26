<#
.SYNOPSIS
    Stage 3 of 3: adds resolved recipients to a static distribution list, then
    reconciles the list against the source so the result is verified, not assumed.

.DESCRIPTION
    Takes the "resolved" CSV from stage 2.
      1. Reads the DL's current members.
      2. Compare-Object works out who is missing; only those are added, so the
         script is safe to re-run after a partial failure.
      3. After adding, it reads the membership again and reconciles:
           - in source, not on DL  -> still missing (should be zero)
           - on DL, not in source  -> extra members (reported, never removed)

    Supports -WhatIf. Always run it with -WhatIf first.

.EXAMPLE
    Connect-ExchangeOnline
    ./3-Add-DistributionListMember.ps1 -InputPath ../output/2-resolved-20261026.csv `
        -DistributionList 'sessional-staff@contoso.com' -WhatIf

.NOTES
    Requires an active Connect-ExchangeOnline session and either ownership of
    the DL or a role that can manage distribution groups. Adding the
    -BypassSecurityGroupManagerCheck switch lets an admin who isn't a DL owner
    make changes; only use it if your role is meant to.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [string]$DistributionList,

    [string]$OutputFolder = './output',

    [switch]$BypassSecurityGroupManagerCheck
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-DistributionGroupMember -ErrorAction SilentlyContinue)) {
    throw 'Exchange Online cmdlets not found. Install ExchangeOnlineManagement and run Connect-ExchangeOnline first.'
}

function Get-DLMemberAddress {
    param([string]$Identity)
    @(Get-DistributionGroupMember -Identity $Identity -ResultSize Unlimited |
        ForEach-Object { "$($_.PrimarySmtpAddress)".ToLowerInvariant() } |
        Where-Object { $_ })
}

$null    = Get-DistributionGroup -Identity $DistributionList   # fails fast if the DL doesn't exist
$desired = @(Import-Csv -Path $InputPath | ForEach-Object { $_.PrimarySmtpAddress.ToLowerInvariant() } | Sort-Object -Unique)
if ($desired.Count -eq 0) { throw "Input file '$InputPath' has no rows." }

$current = Get-DLMemberAddress -Identity $DistributionList
Write-Host ("DL currently has {0} members; source has {1} addresses." -f $current.Count, $desired.Count) -ForegroundColor Cyan

# '<=' = in source but not on the DL
$toAdd = @(if ($current.Count) {
    Compare-Object -ReferenceObject $desired -DifferenceObject $current |
        Where-Object SideIndicator -eq '<=' | Select-Object -ExpandProperty InputObject
} else { $desired })
Write-Host ("  {0} to add" -f $toAdd.Count)

$log = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($member in $toAdd) {
    $i++
    Write-Progress -Activity "Adding to $DistributionList" -Status $member -PercentComplete (($i / $toAdd.Count) * 100)
    if ($PSCmdlet.ShouldProcess($member, "Add to $DistributionList")) {
        try {
            $params = @{ Identity = $DistributionList; Member = $member }
            if ($BypassSecurityGroupManagerCheck) { $params.BypassSecurityGroupManagerCheck = $true }
            Add-DistributionGroupMember @params
            $log.Add([pscustomobject]@{ Member = $member; Action = 'Added'; Detail = '' })
        }
        catch {
            $log.Add([pscustomobject]@{ Member = $member; Action = 'FAILED'; Detail = $_.Exception.Message })
        }
    }
    else {
        $log.Add([pscustomobject]@{ Member = $member; Action = 'WhatIf: would add'; Detail = '' })
    }
}
Write-Progress -Activity "Adding to $DistributionList" -Completed

# --- Verify: re-read the DL and reconcile against the source
$after   = Get-DLMemberAddress -Identity $DistributionList
$diff    = if ($after.Count) { @(Compare-Object -ReferenceObject $desired -DifferenceObject $after) } else { @() }
$missing = @(if ($after.Count) { $diff | Where-Object SideIndicator -eq '<=' | Select-Object -ExpandProperty InputObject } else { $desired })
$extra   = @($diff | Where-Object SideIndicator -eq '=>' | Select-Object -ExpandProperty InputObject)

$report = @(
    $missing | ForEach-Object { [pscustomobject]@{ Address = $_; Status = 'In source, NOT on DL' } }
    $extra   | ForEach-Object { [pscustomobject]@{ Address = $_; Status = 'On DL, not in source' } }
)

New-Item -ItemType Directory -Path $OutputFolder -Force -WhatIf:$false | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath    = Join-Path $OutputFolder "3-log-$stamp.csv"
$reportPath = Join-Path $OutputFolder "3-reconciliation-$stamp.csv"
$log    | Export-Csv -Path $logPath    -NoTypeInformation -WhatIf:$false
$report | Export-Csv -Path $reportPath -NoTypeInformation -WhatIf:$false

Write-Host ''
Write-Host 'Stage 3 complete: membership and reconciliation' -ForegroundColor Cyan
$log | Group-Object Action | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Name, $_.Count) }
Write-Host ("  DL members now        {0}" -f $after.Count)
Write-Host ("  Still missing         {0}" -f $missing.Count) -ForegroundColor ($(if ($missing.Count) { 'Yellow' } else { 'Green' }))
Write-Host ("  Extra (not in source) {0}" -f $extra.Count)
if ($WhatIfPreference -and $toAdd.Count) {
    Write-Host '  (WhatIf run: "still missing" reflects that nothing was actually added.)' -ForegroundColor DarkGray
}
Write-Host "  Action log     : $logPath"
Write-Host "  Reconciliation : $reportPath"
