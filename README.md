# Limble calibration status export

A PowerShell script that pulls every equipment record from Limble CMMS and writes a weekly CSV of calibration status. QA uses it to see what is overdue or coming due, and to keep a dated record for ISO 13485 audits (clause 7.6).

The script only reads from Limble (GET requests). It never changes anything there.

## What it produces

Each run writes two files to the output folder:

- `Calibration_Status_YYYY-MM-DD.csv`, a dated snapshot
- `Calibration_Status_LATEST.csv`, overwritten each run

There is one row per equipment record. Category records such as "Centrifuge" or "Pipettes" are left out; each asset's category appears in its own column. Rows are sorted with the most urgent first.

| Column | Meaning |
|---|---|
| Status | One of the statuses below |
| Days Until Due | Days from today to the next due date (negative means overdue) |
| Next Calibration Due, Last Calibration | From the Limble asset fields of the same names |
| SSBS ID, Asset Name, Category, Make, Model, Serial Number | Identification |
| Usage, Area, Sublocation, Site | Where the asset is and whether it is in service |
| Calibration Required | Yes, No, TBD, or (blank) |
| Certificate Files | Number of files in the asset's Certificate field |
| Limble Asset ID | Limble's internal asset ID |

Statuses, from most to least urgent:

| Status | Meaning |
|---|---|
| OVERDUE - IN USE | Past due and the asset is marked In Use |
| NO DUE DATE | Calibration is required but no due date is recorded |
| DUE WITHIN 30 DAYS | |
| DUE WITHIN 60 DAYS | |
| DECIDE REQUIREMENT | Calibration Required is TBD or blank |
| OVERDUE - NOT IN USE | Past due, but the asset is out of service, quarantined or on loan |
| CURRENT | Due in more than 60 days |
| CALIBRATION NOT REQUIRED | Calibration Required is No |
| RETIRED | Usage is Discarded |

## Requirements

- PowerShell 7 or later
- Network access to `https://21cfr-api.limblecmms.com` (the Limble 21 CFR environment; other Limble environments use different hosts)
- A Limble API client ID and secret, created by a Limble Super Administrator under Settings → Configuration → API Keys

## Setup

1. Store the Limble credentials as user environment variables. They are read at run time and never printed or written to disk by the script.

   ```powershell
   setx LIMBLE_CLIENT_ID "your-client-id"
   setx LIMBLE_CLIENT_SECRET "your-client-secret"
   ```

   Open a new terminal afterwards so the variables are picked up.

2. Run it once by hand:

   ```powershell
   pwsh -File .\Export-LimbleCalibration.ps1
   ```

   Optional parameters:
   - `-OutDir` sets the output folder. The default is the QA Repository shared drive folder "Calibration Status Exports".
   - `-FallbackDir` is used when the output folder's parent doesn't exist, for example when Google Drive isn't mounted.

3. Schedule it. On Windows, register a weekly Task Scheduler task:

   ```powershell
   $action  = New-ScheduledTaskAction -Execute (Get-Command pwsh).Source -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\Export-LimbleCalibration.ps1"'
   $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 7:00am
   $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
   Register-ScheduledTask -TaskName 'Limble Weekly Calibration Export' -Action $action -Trigger $trigger -Settings $settings
   ```

## Logging

Every run appends a line to `export.log` next to the script, with the row count, the output file and a count per status, or the error message if the run failed.

## Notes for running on a server

- Use a dedicated Limble API key for the server, so it can be revoked on its own.
- Store the credentials in a secret store (for example Windows Credential Manager or the PowerShell SecretManagement module) rather than plain environment variables, and update the two lines at the top of the script that read them.
- A server usually has no Google Drive mount. Point `-OutDir` at a network share, or add an upload step.
