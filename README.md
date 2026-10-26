# Bulk distribution list provisioning (Exchange Online)

A three-stage PowerShell workflow that takes a raw list of email addresses, cleans it, makes sure every address exists as a recipient in Exchange Online, adds them to a static distribution list, and then **verifies the result** instead of assuming it worked.

> **About this repo.** In production I built a version of this to provision 8,000+ staff and external addresses into a distribution list against a hard HR deadline. That code belongs to my former employer, so this is a clean-room rebuild of the same design, written from scratch with no organisational data, names or identifiers.

## The problem

HR needed one distribution list to reach a large group of sessional staff. The source list mixed internal staff with external addresses, and, like most exported lists, couldn't be trusted as-is: duplicates, formatting errors and blank rows all had to be caught before anything touched the tenant. <!-- TODO: swap in the real problems you hit --> External people can't be added to a distribution list until they exist in Exchange as mail contacts, and at that scale, doing it by hand was not an option.

## How it works

```
source.csv
   │
   ▼
1-Test-ContactList.ps1          offline · no Exchange connection
   │  → 1-valid.csv  /  1-rejected.csv (with reason per row)
   ▼
2-New-BulkMailContact.ps1       one bulk recipient lookup, then
   │                            create contacts only for unknown addresses
   │  → 2-resolved.csv  /  2-log.csv
   ▼
3-Add-DistributionListMember.ps1  add only who's missing, then
                                  re-read the DL and reconcile
      → 3-log.csv  /  3-reconciliation.csv
```

| Stage | What it does | Key cmdlets |
| --- | --- | --- |
| 1. Validate | Checks required columns, trims whitespace, rejects blank and malformed addresses, removes case-insensitive duplicates | `Import-Csv`, `HashSet` |
| 2. Resolve | Indexes every address in the tenant (including aliases) in one query, then creates mail contacts only for addresses that don't already exist | `Get-EXORecipient`, `New-MailContact`, `Set-MailContact` |
| 3. Add and verify | Works out who's missing from the DL, adds only them, then re-reads membership and reports anything still missing or unexpected | `Compare-Object`, `Add-DistributionGroupMember`, `Get-DistributionGroupMember` |

## Usage

```powershell
# Stage 1: runs offline, try it against the sample data
./scripts/1-Test-ContactList.ps1 -InputPath ./sample/contacts-sample.csv -OutputFolder ./output

# Stages 2 and 3 need Exchange Online
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Connect-ExchangeOnline

# Always dry-run first: -WhatIf changes nothing but still writes the reports
./scripts/2-New-BulkMailContact.ps1 -InputPath ./output/1-valid-<stamp>.csv -HideFromAddressLists -WhatIf
./scripts/2-New-BulkMailContact.ps1 -InputPath ./output/1-valid-<stamp>.csv -HideFromAddressLists

./scripts/3-Add-DistributionListMember.ps1 -InputPath ./output/2-resolved-<stamp>.csv -DistributionList 'list@yourdomain.com' -WhatIf
./scripts/3-Add-DistributionListMember.ps1 -InputPath ./output/2-resolved-<stamp>.csv -DistributionList 'list@yourdomain.com'
```

**Permissions:** use the least privileged role that works, such as Recipient Management, or DL ownership for stage 3. Global Administrator is not needed.

## Design decisions

- **Validate offline, before touching the tenant.** Bad data is cheapest to catch before any change is made. Every rejected row is written out with its reason, so nothing disappears silently and the list owner can fix the source.
- **One bulk lookup instead of one query per row.** At 8,000 rows, per-row lookups are slow and noisy. Stage 2 builds an in-memory index of every SMTP address in the tenant once.
- **Aliases resolve to the primary address.** A staff member listed under an alias is matched to their existing mailbox, not duplicated as a contact.
- **Idempotent.** Stage 3 adds only who is missing, so after a partial failure you simply run it again.
- **Additive only.** Members on the DL who aren't in the source are reported, never removed. Removing people from a live list is a separate decision that deserves a human.
- **Verify, don't assume.** The run ends by re-reading the DL and reconciling it against the source. "Still missing: 0" is the evidence the job is done.
- **Dry run by default habit.** Stages 2 and 3 support `-WhatIf` and still produce their reports, so the change can be reviewed before it's made.
- **Contacts can be hidden from the GAL.** External contacts that exist only to receive DL mail don't need to clutter the address book.

## Testing

- **Stage 1** was run against [`sample/contacts-sample.csv`](sample/contacts-sample.csv), which deliberately includes a padded address, a case-variant duplicate, a missing domain, a double `@`, double dots, a blank email and a row with no names. Five rows pass and five are rejected, each with its reason.
- **Stages 2 and 3** were tested against mocked Exchange cmdlets covering: an alias that resolves to an existing mailbox, a contact creation failure mid-run, a pre-existing DL member not in the source, a `-WhatIf` run (no changes, reports still written), and a re-run (nothing added the second time).
- The production version ran against a live tenant at 8,000+ addresses. This rebuild has not yet been run against a live tenant. <!-- TODO: update once tested in a dev tenant -->

## Security notes

- No credentials are stored anywhere. Authentication is interactive through `Connect-ExchangeOnline` with modern auth and MFA.
- `.gitignore` blocks every CSV except the sample, so real address lists and run output can't be committed by accident.
- The sample data uses Microsoft's reserved example domains (contoso, fabrikam, tailspintoys).
