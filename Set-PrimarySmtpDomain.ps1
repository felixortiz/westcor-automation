<#
.SYNOPSIS
    Changes the primary SMTP proxy address of users listed in a CSV to a new domain.

.DESCRIPTION
    For each user in the CSV:
      - Takes the local part of the current primary SMTP address (e.g. jdoe from SMTP:jdoe@olddomain.com)
      - Demotes the current primary (SMTP:) to a secondary alias (smtp:) so mail to the old address still delivers
      - Promotes the existing alias smtp:<localpart>@wltic.com to SMTP: (users without that alias are skipped)
      - Leaves every other proxy address untouched
      - Updates the 'mail' attribute to match
    The original values are written to a backup CSV before any change.

    CSV format (one column required):
        SamAccountName
        jdoe
        asmith

.EXAMPLE
    .\Set-PrimarySmtpDomain.ps1 -CsvPath .\users.csv -WhatIf
    Shows what would change without writing anything.

.EXAMPLE
    .\Set-PrimarySmtpDomain.ps1 -CsvPath .\users.csv
    Applies the changes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$NewDomain = 'wltic.com',

    [string]$BackupPath = ".\ProxyAddresses_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Import-Module ActiveDirectory -ErrorAction Stop

$users   = Import-Csv -Path $CsvPath
$backup  = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()

foreach ($row in $users) {
    $sam = $row.SamAccountName.Trim()

    try {
        $user = Get-ADUser -Identity $sam -Properties proxyAddresses, mail -ErrorAction Stop
    }
    catch {
        Write-Warning "[$sam] User not found: $($_.Exception.Message)"
        $results.Add([pscustomobject]@{ SamAccountName = $sam; Status = 'NotFound'; OldPrimary = ''; NewPrimary = '' })
        continue
    }

    $proxies = @($user.proxyAddresses)
    $backup.Add([pscustomobject]@{
        SamAccountName = $sam
        Mail           = $user.mail
        ProxyAddresses = $proxies -join ';'
    })

    # Find the current primary (uppercase SMTP:). -cmatch makes the match case-sensitive.
    $currentPrimary = $proxies | Where-Object { $_ -cmatch '^SMTP:' } | Select-Object -First 1
    if (-not $currentPrimary) {
        if ($user.mail) {
            $currentPrimary = "SMTP:$($user.mail)"
        }
        else {
            Write-Warning "[$sam] No primary SMTP address or mail attribute; skipping."
            $results.Add([pscustomobject]@{ SamAccountName = $sam; Status = 'NoPrimary'; OldPrimary = ''; NewPrimary = '' })
            continue
        }
    }

    $oldAddress = $currentPrimary.Substring(5)
    $localPart  = $oldAddress.Split('@')[0]

    # Promote an existing alias in the new domain; never invent one. Prefer the alias whose
    # local part matches the current primary (Dominique.Russell@ over drussell@).
    $candidates = @($proxies | Where-Object { $_ -match "^smtp:[^@]+@$([regex]::Escape($NewDomain))$" } |
        ForEach-Object { $_.Substring(5) })
    $newAddress = $candidates | Where-Object { $_ -ieq "$localPart@$NewDomain" } | Select-Object -First 1
    if (-not $newAddress) {
        Write-Warning "[$sam] No $NewDomain alias matching '$localPart'. Found: $($candidates -join ', '). Skipping."
        $results.Add([pscustomobject]@{ SamAccountName = $sam; Status = 'NoMatchingAlias'; OldPrimary = $oldAddress; NewPrimary = '' })
        continue
    }

    if ($oldAddress -ieq $newAddress) {
        Write-Host "[$sam] Already primary at $newAddress; nothing to do."
        $results.Add([pscustomobject]@{ SamAccountName = $sam; Status = 'AlreadyDone'; OldPrimary = $oldAddress; NewPrimary = $newAddress })
        continue
    }

    # Flip case in place: the current primary becomes smtp:, the chosen alias becomes SMTP:.
    # Every other value (onmicrosoft.com, x500:, other aliases) is left untouched.
    $newProxies = @(foreach ($p in $proxies) {
        if ($p -ieq "smtp:$newAddress")  { "SMTP:$newAddress" }
        elseif ($p -cmatch '^SMTP:')     { 'smtp:' + $p.Substring(5) }
        else                             { $p }
    })

    if ($PSCmdlet.ShouldProcess($sam, "Set primary SMTP $oldAddress -> $newAddress")) {
        try {
            Set-ADUser -Identity $user.DistinguishedName `
                -Replace @{ proxyAddresses = [string[]]$newProxies; mail = $newAddress } `
                -ErrorAction Stop
            Write-Host "[$sam] $oldAddress -> $newAddress" -ForegroundColor Green
            $results.Add([pscustomobject]@{ SamAccountName = $sam; Status = 'Updated'; OldPrimary = $oldAddress; NewPrimary = $newAddress })
        }
        catch {
            Write-Warning "[$sam] Update failed: $($_.Exception.Message)"
            $results.Add([pscustomobject]@{ SamAccountName = $sam; Status = 'Failed'; OldPrimary = $oldAddress; NewPrimary = $newAddress })
        }
    }
    else {
        $results.Add([pscustomobject]@{ SamAccountName = $sam; Status = 'WhatIf'; OldPrimary = $oldAddress; NewPrimary = $newAddress })
    }
}

if (-not $WhatIfPreference -and $backup.Count) {
    $backup | Export-Csv -Path $BackupPath -NoTypeInformation
    Write-Host "Backup of original values written to $BackupPath"
}

$results | Format-Table -AutoSize
