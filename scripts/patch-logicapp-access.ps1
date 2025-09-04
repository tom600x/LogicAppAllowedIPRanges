param(
  [Parameter(Mandatory=$true)]
  [string] $LogicAppResourceId,

  [string] $ArmUrl = "https://azureipranges.azurewebsites.net/getPrefixes/AzureGovernment/LogicApps.USGovTexas",

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

# Download prefixes JSON (robust: try several endpoints and fallbacks)
Write-Host "Downloading prefixes from: $ArmUrl (with fallbacks)"
# candidate URLs to try (include official ARM download endpoint)
$candidates = @(
  "https://azureipranges.azurewebsites.net/downloadARMTemplate/AzureGovernment/LogicApps.USGovTexas",
  $ArmUrl,
  "$ArmUrl/arm",
  "$ArmUrl/arm.json"
)
$resp = $null
$usedUrl = $null
foreach ($u in $candidates) {
  Write-Host "Trying: $u"
  try {
    # Try Invoke-RestMethod first (best when endpoint returns JSON)
    $r = Invoke-RestMethod -Uri $u -UseBasicParsing -ErrorAction Stop
    $resp = $r
    $usedUrl = $u
    break
  } catch {
    # If that fails, try Invoke-WebRequest and parse the content as JSON
    try {
      $r2 = Invoke-WebRequest -Uri $u -UseBasicParsing -ErrorAction Stop
      $content = $r2.Content
      try {
        $resp = $content | ConvertFrom-Json
        $usedUrl = $u
        break
      } catch {
        # not JSON, continue to next candidate
        Write-Host "Response from $u is not JSON or couldn't parse as JSON"
      }
    } catch {
      Write-Host ("Failed to download from {0}: {1}" -f $u, $_.Exception.Message)
    }
  }
}

if (-not $resp) {
  throw "Failed to fetch or parse JSON from any candidate URL. Checked: $($candidates -join ', ')"
}
Write-Host "Using prefix source: $usedUrl"

# After successful download and before extracting prefixes, keep raw JSON text if available
if (-not $content -and $usedUrl) {
  try { $content = (Invoke-WebRequest -Uri $usedUrl -UseBasicParsing -ErrorAction Stop).Content } catch {}
}

# Extract prefixes from common shapes (extended to handle ARM template routeTables)
$prefixes = @()
if ($resp -is [System.Array]) {
  $prefixes = $resp
} elseif ($resp.values) {
  foreach ($v in $resp.values) {
    if ($v.properties -and $v.properties.addressPrefixes) { $prefixes += $v.properties.addressPrefixes }
    elseif ($v.properties -and $v.properties.addressPrefix) { $prefixes += $v.properties.addressPrefix }
  }
} elseif ($resp.prefixes) {
  $prefixes = $resp.prefixes
} elseif ($resp.resources) {
  # ARM template style: look for routeTables resources
  foreach ($rsc in $resp.resources) {
    if ($rsc.type -like 'Microsoft.Network/routeTables*' -and $rsc.properties -and $rsc.properties.routes) {
      foreach ($rt in $rsc.properties.routes) {
        if ($rt.properties -and $rt.properties.addressPrefix) { $prefixes += $rt.properties.addressPrefix }
      }
    }
  }
} elseif ($resp.properties -and $resp.properties.addressPrefixes) {
  $prefixes = $resp.properties.addressPrefixes
}

# Regex fallback if still empty (scan raw content for IPv4/IPv6 CIDR strings)
if (-not $prefixes -or $prefixes.Count -eq 0) {
  Write-Host "Structured parsing found no prefixes; attempting regex extraction from raw content..."
  if (-not $content -and $usedUrl) {
    try {
      $raw = Invoke-WebRequest -Uri $usedUrl -UseBasicParsing -ErrorAction Stop
      $content = $raw.Content
    } catch {
      Write-Host "Failed to re-download raw content for regex parsing: $($_.Exception.Message)"
    }
  }
  if ($content) {
    $ipv4Pattern = '(?<!\d)(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\/(?:[0-9]|[12][0-9]|3[0-2])'
    $ipv6Pattern = '(?:[A-Fa-f0-9]{1,4}:){1,7}[A-Fa-f0-9]{1,4}\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])'
  $ipv4Matches = [System.Text.RegularExpressions.Regex]::Matches($content, $ipv4Pattern)
  $matchesV6 = [System.Text.RegularExpressions.Regex]::Matches($content, $ipv6Pattern)
    $all = @()
  foreach ($m in $ipv4Matches) { $all += $m.Value }
    foreach ($m in $matchesV6) { $all += $m.Value }
    $prefixes = $all | Select-Object -Unique
    if ($prefixes.Count -gt 0) {
      Write-Host "Regex fallback extracted $($prefixes.Count) prefixes"
    }
  }
}

if (-not $prefixes -or $prefixes.Count -eq 0) {
  throw "No prefixes found in downloaded content from $usedUrl. Save the file manually and inspect; adjust regex or source URL."
}

# flatten and unique
$prefixes = $prefixes | ForEach-Object { $_ } | Where-Object { $_ } | Select-Object -Unique
Write-Host "Found $($prefixes.Count) prefixes"

# Handle Microsoft.Web/sites (App Service) - existing behavior
if ($LogicAppResourceId -like "*/Microsoft.Web/sites/*") {
  Write-Host "Detected App Service resource. Using web config path."

  # Build management API uri for config/web
  $uriPath = "$LogicAppResourceId/config/web?api-version=$ApiVersion"
  $uri = "https://management.azure.com$uriPath"
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
      name = "AzureGov_LogicApps_USGovTX_$idx"
      description = "Auto-updated from $ArmUrl"
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
      if (-not ($name -and $name -match '^AzureGov_LogicApps_USGovTX_')) {
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
      $uri = 'https://management.azure.com' + $LogicAppResourceId + '?api-version=' + $v
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
        $uri = 'https://management.azure.com' + $LogicAppResourceId + '?api-version=' + $usedApiVersion
      } else {
        throw "Failed to retrieve existing workflow resource after trying API versions: $($candidateApiVersions -join ', ')"
      }
    }
  } else {
    Write-Host "SkipFetchExisting specified. Building patch body without existing workflow GET." -ForegroundColor Yellow
    $existing = @{ properties = @{} }
    $usedApiVersion = $candidateApiVersions[0]
    $uri = 'https://management.azure.com' + $LogicAppResourceId + '?api-version=' + $usedApiVersion
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
      Write-Host "No changes detected in accessControl (triggers$([string]::IsNullOrEmpty([string]$includeContents) ? '' : '/contents')); skipping update." -ForegroundColor Yellow
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
