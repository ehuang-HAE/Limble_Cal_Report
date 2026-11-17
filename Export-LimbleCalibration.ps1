<#
  Weekly Limble calibration status export (read-only).
  Pulls every equipment record from Limble (21 CFR host; category/group records are skipped), with calibration
  dates where they exist, and writes a dated CSV plus "Calibration_Status_LATEST.csv" to the QA Repository shared drive.
  Credentials: user environment variables LIMBLE_CLIENT_ID / LIMBLE_CLIENT_SECRET (never printed or saved).
  Only GET requests are made; nothing in Limble is changed.
#>
param(
  [string]$OutDir = 'G:\Shared drives\Operations\Slingshot - QA Repository\Equipment\Calibration Status Exports',
  [string]$FallbackDir = 'C:\Users\EricHuang\Projects\limble-iso13485-audit\exports'
)
$ErrorActionPreference = 'Stop'
$logFile = Join-Path $PSScriptRoot 'export.log'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content -Path $logFile }

try {
  $id  = [Environment]::GetEnvironmentVariable('LIMBLE_CLIENT_ID', 'User')
  $sec = [Environment]::GetEnvironmentVariable('LIMBLE_CLIENT_SECRET', 'User')
  if (-not $id -or -not $sec) { throw 'Limble credentials are not set in the user environment variables.' }
  $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($id.Trim()):$($sec.Trim())")) }
  $base = 'https://21cfr-api.limblecmms.com/v2'

  function Get-All($path) {
    $all = @(); $page = 1
    do {
      $sep = if ($path -match '\?') { '&' } else { '?' }
      $batch = @(Invoke-RestMethod -Uri "$base/$path${sep}limit=500&page=$page" -Headers $headers -Method Get | ForEach-Object { $_ })
      $all += $batch; $page++
    } while ($batch.Count -eq 500 -and $page -lt 200)
    $all
  }

  $assets    = Get-All 'assets'
  $fields    = Get-All 'assets/fields'
  $locations = @(Get-All 'locations')
  $locName = @{}; foreach ($l in $locations) { $locName[[int]$l.locationID] = $l.name }
  $assetName = @{}; foreach ($a in $assets) { $assetName[[int]$a.assetID] = $a.name }
  $hasChildren = @{}; foreach ($a in $assets) { if ($a.parentAssetID) { $hasChildren[[int]$a.parentAssetID] = $true } }

  $vals = @{}
  foreach ($f in $fields) {
    $k = [int]$f.assetID
    if (-not $vals.ContainsKey($k)) { $vals[$k] = @{} }
    $v = if ($f.fieldType -eq 'Documents') { @($f.files).Count } else { $f.value }
    if ($v -is [string]) { $v = ($v -replace '<[^>]+>', '').Trim() }
    $vals[$k][$f.field] = $v
  }
  function D($v) { if (-not $v) { return $null }; try { return ([datetime]$v).Date } catch { return $null } }

  $today = (Get-Date).Date
  $rows = foreach ($a in $assets) {
    $aid = [int]$a.assetID
    if ($hasChildren[$aid]) { continue }               # skip category/group records
    $v = $vals[$aid]; if (-not $v) { $v = @{} }
    $req = [string]$v['Calibration Required']
    $usage = [string]$v['Useage']
    $last = D $v['Last Calibration']; $next = D $v['Next Calibration Due']
    $days = if ($next) { ($next - $today).Days } else { $null }
    $inUse = $usage -in @('In Use', '')
    $status =
      if ($req -eq 'No') { 'CALIBRATION NOT REQUIRED' }
      elseif ($req -ne 'Yes') { 'DECIDE REQUIREMENT' }
      elseif ($usage -in 'Discarded') { 'RETIRED' }
      elseif (-not $next) { 'NO DUE DATE' }
      elseif ($days -lt 0) { if ($inUse) { 'OVERDUE - IN USE' } else { 'OVERDUE - NOT IN USE' } }
      elseif ($days -le 30) { 'DUE WITHIN 30 DAYS' }
      elseif ($days -le 60) { 'DUE WITHIN 60 DAYS' }
      else { 'CURRENT' }
    [pscustomobject][ordered]@{
      'Status'               = $status
      'Days Until Due'       = $days
      'Next Calibration Due' = if ($next) { $next.ToString('yyyy-MM-dd') } else { '' }
      'Last Calibration'     = if ($last) { $last.ToString('yyyy-MM-dd') } else { '' }
      'SSBS ID'              = [string]$v['SSBS ID']
      'Asset Name'           = $a.name
      'Category'             = if ($a.parentAssetID) { $assetName[[int]$a.parentAssetID] } else { '' }
      'Make'                 = [string]$v['Make']
      'Model'                = [string]$v['Model']
      'Serial Number'        = [string]$v['Serial Number']
      'Usage'                = $usage
      'Area'                 = [string]$v['Location']
      'Sublocation'          = [string]$v['Sublocation']
      'Calibration Required' = if ($req) { $req } else { '(blank)' }
      'Certificate Files'    = [int]$v['Certificate']
      'Limble Asset ID'      = $aid
      'Site'                 = $locName[[int]$a.locationID]
    }
  }
  $order = @{ 'OVERDUE - IN USE' = 0; 'NO DUE DATE' = 1; 'DUE WITHIN 30 DAYS' = 2; 'DUE WITHIN 60 DAYS' = 3; 'DECIDE REQUIREMENT' = 4; 'OVERDUE - NOT IN USE' = 5; 'CURRENT' = 6; 'CALIBRATION NOT REQUIRED' = 7; 'RETIRED' = 8 }
  $rows = $rows | Sort-Object @{ e = { $order[$_.Status] } }, @{ e = { if ($null -eq $_.'Days Until Due') { 99999 } else { $_.'Days Until Due' } } }, 'SSBS ID'

  $target = $OutDir
  if (-not (Test-Path (Split-Path $OutDir -Parent))) { $target = $FallbackDir; Log "Shared drive not available; writing to $FallbackDir" }
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  $stamp = $today.ToString('yyyy-MM-dd')
  $dated = Join-Path $target "Calibration_Status_$stamp.csv"
  $rows | Export-Csv -Path $dated -Encoding utf8BOM
  Copy-Item $dated (Join-Path $target 'Calibration_Status_LATEST.csv') -Force

  $summary = ($rows | Group-Object Status | Sort-Object { $order[$_.Name] } | ForEach-Object { "$($_.Name): $($_.Count)" }) -join '; '
  Log "OK  $($rows.Count) assets -> $dated  [$summary]"
  "Wrote $($rows.Count) assets to $dated"
  $summary
}
catch {
  Log "FAILED  $($_.Exception.Message)"
  throw
}
