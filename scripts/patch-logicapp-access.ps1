param(
  [Parameter(Mandatory=$true)]
  [string] $LogicAppResourceId,

  [ValidateNotNullOrEmpty()]
  [string] $ServiceTag = 'LogicApps',

  [ValidateSet('Commercial','Government')]
  [string] $Cloud = 'Commercial',

  [string] $ApiVersion = "2021-02-01",

  [ValidateSet('Trigger','Content','Both')]
  [string] $Target = 'Trigger',

  [switch] $WhatIf,

  # Optional: skip retrieving existing workflow/site (useful for dry-run generation when ID is placeholder)
  [switch] $SkipFetchExisting,

  # When set (Consumption only) also updates the content (response) access control block. Default false.
  [switch] $IncludeContentAccess
)

$ErrorActionPreference = 'Stop'
Write-Host "Starting Logic App accessRestrictions update for: $LogicAppResourceId (Target: $Target)"

if (-not $LogicAppResourceId) {
  throw "LogicAppResourceId is required. Example: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<name> or /providers/Microsoft.Logic/workflows/<workflow>"
}

$downloadPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=56519'
$filePattern = 'ServiceTags_Public_.*\.json'
$managementEndpoint = 'https://management.azure.com'
if ($Cloud -eq 'Government') {
  $downloadPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=57063'
  $filePattern = 'ServiceTags_AzureGovernment_.*\.json'
  $managementEndpoint = 'https://management.usgovcloudapi.net'
}
$downloadFolder = Join-Path $PSScriptRoot 'ServiceTags'
if (-not (Test-Path -LiteralPath $downloadFolder -PathType Container)) {
  New-Item -Path $downloadFolder -ItemType Directory -ErrorAction Stop | Out-Null
}

Write-Host "Discovering service tags download from: $downloadPage"
$page = Invoke-WebRequest -Uri $downloadPage -UseBasicParsing -ErrorAction Stop
$jsonUrl = $page.Links |
  Where-Object href -match $filePattern |
  Select-Object -First 1 -ExpandProperty href
if (-not $jsonUrl) {
  throw "No $Cloud service tags JSON download link found on $downloadPage."
}
$downloadUri = [uri]::new([uri]$downloadPage, $jsonUrl)
if ($downloadUri.Scheme -ne 'https') {
  throw "Expected an HTTPS service tags download link, found: $downloadUri"
}

$outFile = Join-Path $downloadFolder $downloadUri.Segments[-1]
Invoke-WebRequest -Uri $downloadUri.AbsoluteUri -OutFile $outFile -UseBasicParsing -ErrorAction Stop
Write-Host "Downloaded $outFile"
$resp = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json -ErrorAction Stop
$matchingTags = @($resp.values | Where-Object { $_.name -eq $ServiceTag })
if ($matchingTags.Count -eq 0) {
  throw "Service tag '$ServiceTag' was not found in $outFile. Specify an exact service tag name from the $Cloud cloud feed."
}
$prefixes = @($matchingTags | ForEach-Object { $_.properties.addressPrefixes } |
  Where-Object { $_ } | Select-Object -Unique)
if ($prefixes.Count -eq 0) {
  throw "No address prefixes found for service tag '$ServiceTag' in $outFile."
}
Write-Host "Found $($prefixes.Count) prefixes for service tag '$ServiceTag'"

# Handle Microsoft.Web/sites (App Service) - existing behavior
if ($LogicAppResourceId -like "*/Microsoft.Web/sites/*") {
  Write-Host "Detected App Service resource. Using web config path."

  # Build management API uri for config/web
  $uriPath = "$LogicAppResourceId/config/web?api-version=$ApiVersion"
  $uri = "$managementEndpoint$uriPath"
  Write-Host "Management URI: $uri"

  # Build ipSecurityRestrictions entries
  $ipSecurityRestrictions = @()
  $priorityBase = 100
  $idx = 0
  foreach ($p in $prefixes) {
    $idx++
    $entry = @{
      ipAddress = "$p"
      action = "Allow"
      priority = $priorityBase + $idx
      name = "ServiceTag_${ServiceTag}_$idx"
      description = "Auto-updated from service tag '$ServiceTag' ($($downloadUri.AbsoluteUri))"
    }
    $ipSecurityRestrictions += $entry
  }

  # Retrieve existing config to preserve non-auto rules
  Write-Host "Retrieving existing web config to preserve non-auto rules"
  $existing = az rest --method get --uri $uri | ConvertFrom-Json

  $preserve = @()
  if ($existing) {
    if ($existing.properties -and $existing.properties.ipSecurityRestrictions) {
      $existingEntries = $existing.properties.ipSecurityRestrictions
    } elseif ($existing.ipSecurityRestrictions) {
      $existingEntries = $existing.ipSecurityRestrictions
    } else {
      $existingEntries = @()
    }

    foreach ($e in $existingEntries) {
      $name = $e.name -as [string]
      if (-not ($name -and $name -match '^(AzureGov_LogicApps_USGovTX_|ServiceTag_)')) {
        $preserve += $e
      }
    }
  }

  # Merge preserve entries and new ip entries. Reassign priorities
  $merged = @()
  $priority = 10
  foreach ($p in $preserve) {
    $p.priority = $priority; $priority += 10
    $merged += $p
  }
  foreach ($p in $ipSecurityRestrictions) {
    $p.priority = $priority; $priority += 10
    $merged += $p
  }

  $body = @{ properties = @{ ipSecurityRestrictions = $merged } }
  $bodyJson = $body | ConvertTo-Json -Depth 20

  if ($WhatIf) {
    Write-Host "WhatIf: PUT body would be:`n$bodyJson"
    return
  }

  $tempFile = Join-Path $env:TEMP ("logicapp_std_" + [guid]::NewGuid().ToString() + ".json")
  $bodyJson | Set-Content -Path $tempFile -Encoding utf8
  Write-Host "Temp body file: $tempFile"

  Write-Host "Applying updated ipSecurityRestrictions (total entries: $($merged.Count))"
  try {
  $result = az rest --method put --uri $uri --headers "Content-Type=application/json" --body @$tempFile | ConvertFrom-Json
    Write-Host "Update succeeded."
  } catch {
    throw "Failed to update web config: $($_.Exception.Message)"
  } finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -ErrorAction SilentlyContinue }
  }

  # Verification GET
  try {
    $verify = az rest --method get --uri $uri | ConvertFrom-Json
    $ruleCount = ($verify.properties.ipSecurityRestrictions | Measure-Object).Count
    Write-Host "Verification: ipSecurityRestrictions count = $ruleCount"
  } catch { Write-Host "Verification GET failed: $($_.Exception.Message)" -ForegroundColor Yellow }

  Write-Host "Done (Standard)."
  return
}

# Handle Microsoft.Logic/workflows (Consumption)
if ($LogicAppResourceId -like "*/Microsoft.Logic/workflows/*") {
  Write-Host "Detected Consumption Logic App (Microsoft.Logic/workflows). Will apply workflow access control. Target param=$Target IncludeContentAccess=$IncludeContentAccess"

  # Use a Logic Apps API version by default; allow override via $ApiVersion
  if (-not $ApiVersion -or $ApiVersion -eq '2021-02-01') { $ApiVersion = '2019-05-01' }
  $candidateApiVersions = @($ApiVersion, '2019-05-01', '2016-06-01') | Select-Object -Unique

  Write-Host "Raw LogicAppResourceId: '$LogicAppResourceId' (len=$($LogicAppResourceId.Length))"
  Write-Host "Attempting to retrieve workflow using candidate API versions: $($candidateApiVersions -join ', ')"

  $existing = $null
  $usedApiVersion = $null
  if (-not $SkipFetchExisting) {
    foreach ($v in $candidateApiVersions) {
      $uri = $managementEndpoint + $LogicAppResourceId + '?api-version=' + $v
      Write-Host "Trying URI: $uri"
      try {
        $existing = az rest --method get --uri $uri | ConvertFrom-Json
        if ($existing) { $usedApiVersion = $v; break }
      } catch {
        Write-Host "GET failed for api-version $v : $($_.Exception.Message)"  
      }
    }
    if (-not $existing) {
      if ($WhatIf) {
        Write-Host "Warning: Could not retrieve existing workflow (WhatIf mode). Proceeding with empty baseline due to -WhatIf and potential placeholder resource id." -ForegroundColor Yellow
        $existing = @{ properties = @{} }
        $usedApiVersion = $candidateApiVersions[0]
        $uri = $managementEndpoint + $LogicAppResourceId + '?api-version=' + $usedApiVersion
      } else {
        throw "Failed to retrieve existing workflow resource after trying API versions: $($candidateApiVersions -join ', ')"
      }
    }
  } else {
    Write-Host "SkipFetchExisting specified. Building patch body without existing workflow GET." -ForegroundColor Yellow
    $existing = @{ properties = @{} }
    $usedApiVersion = $candidateApiVersions[0]
    $uri = $managementEndpoint + $LogicAppResourceId + '?api-version=' + $usedApiVersion
  }

  Write-Host "Using API version: $usedApiVersion"
  Write-Host "Management URI: $uri"
  Write-Host "Sample prefixes (first 5): $((($prefixes | Select-Object -First 5) -join ', '))"

  if (-not $existing) {
    throw "Failed to retrieve existing workflow resource."
  }

  # Build full PUT body (PATCH to workflow properties isn't supported).
  # Sanitize existing properties: keep definition, parameters, and selected optional fields.
  $ipObjects = @(); foreach ($pfx in $prefixes) { $ipObjects += @{ addressRange = $pfx } }

  # Determine whether to include contents block (new switch supersedes -Target for content)
  $includeContents = $false
  if ($IncludeContentAccess) { $includeContents = $true }
  elseif ($Target -in @('Content','Both')) { $includeContents = $true }

  $newAccess = @{}
  # Always manage triggers (safer default)
  $newAccess.triggers = @{ allowedCallerIpAddresses = $ipObjects }
  if ($includeContents) { $newAccess.contents = @{ allowedCallerIpAddresses = $ipObjects } }

  # Idempotence: if existing accessControl already matches desired sets, skip PUT
  if (-not $WhatIf -and -not $SkipFetchExisting -and $existing.properties.accessControl) {
    $existingTriggers = @()
    if ($existing.properties.accessControl.triggers.allowedCallerIpAddresses) {
      $existingTriggers = $existing.properties.accessControl.triggers.allowedCallerIpAddresses | ForEach-Object { $_.addressRange }
    }
    $existingContents = @()
    if ($includeContents -and $existing.properties.accessControl.contents.allowedCallerIpAddresses) {
      $existingContents = $existing.properties.accessControl.contents.allowedCallerIpAddresses | ForEach-Object { $_.addressRange }
    }
    function __setEqual($a,$b){
      $a2 = @($a | Sort-Object -Unique); $b2 = @($b | Sort-Object -Unique); return ($a2.Count -eq $b2.Count) -and (@($a2 -join ',') -eq @($b2 -join ',')) }
    $trgEqual = __setEqual ($existingTriggers) ($ipObjects.addressRange)
    $cntEqual = $true
    if ($includeContents) { $cntEqual = __setEqual ($existingContents) ($ipObjects.addressRange) }
    if ($trgEqual -and $cntEqual) {
      $contentsSuffix = if ($includeContents) { '/contents' } else { '' }
      Write-Host "No changes detected in accessControl (triggers$contentsSuffix); skipping update." -ForegroundColor Yellow
      Write-Host "Verification (skip): triggers=$($existingTriggers.Count) contents=$($existingContents.Count)"
      return
    }
  }

  # Start properties set with required fields
  $putProperties = @{}
  if ($existing.properties.definition) { $putProperties.definition = $existing.properties.definition }
  if ($existing.properties.parameters) { $putProperties.parameters = $existing.properties.parameters }
  if ($existing.properties.integrationAccount) { $putProperties.integrationAccount = $existing.properties.integrationAccount }
  if ($existing.properties.kind) { $putProperties.kind = $existing.properties.kind }
  if ($existing.properties.sku) { $putProperties.sku = $existing.properties.sku }
  if ($existing.properties.state) { $putProperties.state = $existing.properties.state }
  if ($newAccess.Count -gt 0) { $putProperties.accessControl = $newAccess }

  $putBody = @{ location = $existing.location; properties = $putProperties }
  if ($existing.tags) { $putBody.tags = $existing.tags }

  $bodyJson = $putBody | ConvertTo-Json -Depth 50

  if ($WhatIf) {
    Write-Host "WhatIf: PUT body would be:`n$bodyJson"
    return
  }

  $tempFile = Join-Path $env:TEMP ("logicapp_wf_" + [guid]::NewGuid().ToString() + ".json")
  $bodyJson | Set-Content -Path $tempFile -Encoding utf8
  Write-Host "Temp body file: $tempFile"

  Write-Host "Applying PUT (full update) to workflow resource (adding accessControl)"
  try {
    $result = az rest --method put --uri $uri --headers "Content-Type=application/json" --body @$tempFile | ConvertFrom-Json
    Write-Host "PUT request sent."
  } catch {
    throw "Failed to PUT workflow resource: $($_.Exception.Message)"
  } finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -ErrorAction SilentlyContinue }
  }

  Start-Sleep -Seconds 3
  # Verification GET
  try {
    $post = az rest --method get --uri $uri | ConvertFrom-Json
    $trgCount = ($post.properties.accessControl.triggers.allowedCallerIpAddresses | Measure-Object).Count
    $cntCount = 0
    if ($post.properties.accessControl -and ($post.properties.accessControl.PSObject.Properties.Name -contains 'contents')) {
      $cntCount = ($post.properties.accessControl.contents.allowedCallerIpAddresses | Measure-Object).Count
    }
    Write-Host "Verification: triggers=$trgCount contents=$cntCount (expected=$($prefixes.Count))"
    if ($Target -in @('Trigger','Both') -and $trgCount -ne $prefixes.Count) { Write-Host "Warning: Trigger IP count mismatch" -ForegroundColor Yellow }
    if ($Target -in @('Content','Both') -and $cntCount -ne $prefixes.Count) { Write-Host "Warning: Contents IP count mismatch" -ForegroundColor Yellow }
  } catch { Write-Host "Verification GET failed: $($_.Exception.Message)" -ForegroundColor Yellow }

  Write-Host "Done (Consumption)."
  return
}

throw "Unsupported resource id type. Provide a Microsoft.Web/sites or Microsoft.Logic/workflows resource id."
