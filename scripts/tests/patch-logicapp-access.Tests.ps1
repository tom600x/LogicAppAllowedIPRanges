$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'patch-logicapp-access.ps1'

function az {
  throw 'Tests must not invoke the Azure CLI without a mock.'
}

Describe 'Service tag access restrictions' {
  BeforeEach {
    $global:LogicAppAccessTestState = @{
      Messages = @()
      DownloadUrl = $null
      DownloadPath = $null
      ManagementUri = $null
      Link = 'https://download.microsoft.com/download/example/ServiceTags_Public_20990101.json'
    }
    $global:LogicAppAccessTestState.Feed = @{
      values = @(
        @{ name = 'LogicApps'; properties = @{ addressPrefixes = @('192.0.2.0/24', '2001:db8::/48', '192.0.2.0/24') } }
        @{ name = 'LogicApps.EastUS'; properties = @{ addressPrefixes = @('198.51.100.0/24') } }
        @{ name = 'LogicApps.USGovTexas'; properties = @{ addressPrefixes = @('203.0.113.0/24') } }
      )
    } | ConvertTo-Json -Depth 10
    $script:arguments = @{
      LogicAppResourceId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Logic/workflows/test'
      WhatIf = $true
      SkipFetchExisting = $true
    }

    Mock Write-Host { $global:LogicAppAccessTestState.Messages += "$Object" }
    Mock Test-Path { $true }
    Mock Get-Content { $global:LogicAppAccessTestState.Feed }
    Mock Invoke-WebRequest {
      if ($OutFile) {
        $global:LogicAppAccessTestState.DownloadUrl = "$Uri"
        $global:LogicAppAccessTestState.DownloadPath = $OutFile
      } else {
        @{ Links = @([pscustomobject]@{ href = $global:LogicAppAccessTestState.Link }) }
      }
    }
    Mock az {
      $global:LogicAppAccessTestState.ManagementUri = $args[$args.IndexOf('--uri') + 1]
      @{
        properties = @{
          ipSecurityRestrictions = @(
            @{ name = 'ManualRule'; ipAddress = '10.0.0.0/8'; priority = 1; action = 'Allow' }
            @{ name = 'AzureGov_LogicApps_USGovTX_1'; ipAddress = '10.1.0.0/16'; priority = 2; action = 'Allow' }
            @{ name = 'ServiceTag_Previous_1'; ipAddress = '10.2.0.0/16'; priority = 3; action = 'Allow' }
          )
        }
      } | ConvertTo-Json -Depth 10
    }
  }

  AfterAll {
    Remove-Variable -Name LogicAppAccessTestState -Scope Global
  }

  It 'downloads the published changing filename and selects only the exact tag' {
    & $scriptPath @script:arguments
    $global:LogicAppAccessTestState.DownloadUrl | Should Be $global:LogicAppAccessTestState.Link
    (Split-Path $global:LogicAppAccessTestState.DownloadPath -Leaf) | Should Be 'ServiceTags_Public_20990101.json'
    $body = ($global:LogicAppAccessTestState.Messages | Where-Object { $_ -like 'WhatIf: PUT body*' }) -replace '^WhatIf: PUT body would be:\s*', '' | ConvertFrom-Json
    $prefixes = @($body.properties.accessControl.triggers.allowedCallerIpAddresses.addressRange)
    $prefixes.Count | Should Be 2
    ($prefixes -contains '192.0.2.0/24') | Should Be $true
    ($prefixes -contains '2001:db8::/48') | Should Be $true
  }

  It 'selects a regional tag without including the global tag' {
    & $scriptPath @script:arguments -ServiceTag 'LogicApps.EastUS' -IncludeContentAccess
    $body = ($global:LogicAppAccessTestState.Messages | Where-Object { $_ -like 'WhatIf: PUT body*' }) -replace '^WhatIf: PUT body would be:\s*', '' | ConvertFrom-Json
    $body.properties.accessControl.triggers.allowedCallerIpAddresses.Count | Should Be 1
    $body.properties.accessControl.triggers.allowedCallerIpAddresses[0].addressRange | Should Be '198.51.100.0/24'
    $body.properties.accessControl.contents.allowedCallerIpAddresses[0].addressRange | Should Be '198.51.100.0/24'
  }

  It 'uses the Government page, filename, and management endpoint' {
    $global:LogicAppAccessTestState.Link = 'https://download.microsoft.com/download/example/ServiceTags_AzureGovernment_20990108.json'
    & $scriptPath @script:arguments -Cloud Government -ServiceTag 'LogicApps.USGovTexas'
    Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { "$Uri" -eq 'https://www.microsoft.com/en-us/download/details.aspx?id=57063' }
    $global:LogicAppAccessTestState.DownloadUrl | Should Be $global:LogicAppAccessTestState.Link
    ($global:LogicAppAccessTestState.Messages -join "`n") | Should Match 'https://management.usgovcloudapi.net/'
    $body = ($global:LogicAppAccessTestState.Messages | Where-Object { $_ -like 'WhatIf: PUT body*' }) -replace '^WhatIf: PUT body would be:\s*', '' | ConvertFrom-Json
    $body.properties.accessControl.triggers.allowedCallerIpAddresses[0].addressRange | Should Be '203.0.113.0/24'
  }

  It 'resolves relative download links' {
    $global:LogicAppAccessTestState.Link = '/download/ServiceTags_Public_20990115.json'
    & $scriptPath @script:arguments
    $global:LogicAppAccessTestState.DownloadUrl | Should Be 'https://www.microsoft.com/download/ServiceTags_Public_20990115.json'
  }

  It 'fails before contacting Azure when no download link is present' {
    $global:LogicAppAccessTestState.Link = '/unrelated.json'
    { & $scriptPath @script:arguments } | Should Throw 'No Commercial service tags JSON download link'
    Assert-MockCalled az -Times 0 -Exactly
  }

  It 'rejects insecure download links' {
    $global:LogicAppAccessTestState.Link = 'http://download.microsoft.com/ServiceTags_Public_20990101.json'
    { & $scriptPath @script:arguments } | Should Throw 'Expected an HTTPS'
    Assert-MockCalled az -Times 0 -Exactly
  }

  It 'fails for an unknown tag without using other tags' {
    { & $scriptPath @script:arguments -ServiceTag Missing } | Should Throw "Service tag 'Missing' was not found"
    Assert-MockCalled az -Times 0 -Exactly
  }

  It 'fails for a tag without address prefixes' {
    $global:LogicAppAccessTestState.Feed = '{"values":[{"name":"LogicApps","properties":{"addressPrefixes":[]}}]}'
    { & $scriptPath @script:arguments } | Should Throw 'No address prefixes found'
    Assert-MockCalled az -Times 0 -Exactly
  }

  It 'fails on malformed downloaded JSON' {
    $global:LogicAppAccessTestState.Feed = 'not JSON'
    { & $scriptPath @script:arguments } | Should Throw 'Conversion from JSON failed'
    Assert-MockCalled az -Times 0 -Exactly
  }

  It 'preserves manual Standard rules and replaces legacy and previous service tag rules' {
    $global:LogicAppAccessTestState.Link = 'https://download.microsoft.com/download/example/ServiceTags_AzureGovernment_20990108.json'
    $script:arguments.LogicAppResourceId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Web/sites/test'
    & $scriptPath @script:arguments -Cloud Government -ServiceTag 'LogicApps.USGovTexas'
    $global:LogicAppAccessTestState.ManagementUri | Should Match '^https://management.usgovcloudapi.net/'
    $body = ($global:LogicAppAccessTestState.Messages | Where-Object { $_ -like 'WhatIf: PUT body*' }) -replace '^WhatIf: PUT body would be:\s*', '' | ConvertFrom-Json
    $rules = @($body.properties.ipSecurityRestrictions)
    $rules.Count | Should Be 2
    $rules[0].name | Should Be 'ManualRule'
    $rules[1].name | Should Be 'ServiceTag_LogicApps.USGovTexas_1'
    $rules[1].ipAddress | Should Be '203.0.113.0/24'
  }
}
