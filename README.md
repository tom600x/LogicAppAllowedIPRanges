Nightly Logic App IP allowlist updater

This repository contains an Azure DevOps pipeline and a PowerShell script that download Microsoft Azure Commercial or Government service tag IP prefixes and patch either:

## 📹 Setup Video

For a complete walkthrough of the setup process, watch the setup video:

**[📥 Download Setup Video (247 MB)](./Setup%20Video.mp4)**

*Note: Click the link above to download the video file, then open it with your preferred media player.*

## Overview

This repository contains an Azure DevOps pipeline and a PowerShell script that download Microsoft Azure Commercial or Government service tag IP prefixes and patch either:

1. Logic App Standard (App Service) ipSecurityRestrictions (config/web)
2. Logic App Consumption workflow accessControl (triggers / contents allowedCallerIpAddresses)

Supported resource id patterns:
- Standard: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<siteName>
- Consumption: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/<workflowName>

Files
- `.azure-pipelines.yml` — Azure DevOps YAML pipeline (nightly) invoking the script
- `scripts/patch-logicapp-access.ps1` — PowerShell script that downloads prefixes and updates either web config ipSecurityRestrictions (Standard) or workflow accessControl (Consumption)

Quick setup
1) Create a service principal scoped to the target resource group
   az login
   az account set --subscription "<SUBSCRIPTION_ID>"
   az ad sp create-for-rbac --name "sp-devops-logicapp" --role "Contributor" --scopes "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>" --sdk-auth > sp-auth.json
   Keep sp-auth.json private. Use it to create an Azure Resource Manager service connection in Azure DevOps.

2) Create an Azure DevOps service connection
   - Project settings -> Service connections -> New service connection -> Azure Resource Manager
   - Use the 'Service principal (manual)' option and paste values from sp-auth.json
   - Name the connection and update the `azureSubscription` variable in `.azure-pipelines.yml` with that name

3) Configure pipeline variables (in `.azure-pipelines.yml`)
   - `azureSubscription` — service connection name
   - `logicAppResourceId` — full resource id (Standard or Consumption)
   - `cloud` — pipeline runtime parameter: `Commercial` (default) or `Government`. Use a service connection configured for the selected cloud.
   - `serviceTag` — pipeline runtime parameter; exact service tag name (default `LogicApps`, or a regional tag such as `LogicApps.EastUS`). For Government, for example, use `LogicApps.USGovTexas`. Select both parameters when running manually; edit their defaults for scheduled runs.
   - `apiVersion` — Standard web config API version (default 2021-02-01). Consumption auto-tries appropriate workflow versions.
   - `includeContentAccess` — set to `true` to also manage `contents.allowedCallerIpAddresses` (Consumption). Defaults to false.

4) Commit & create pipeline
   - Commit these files to your repo
   - In Azure DevOps: Pipelines -> New pipeline -> Azure Repos Git -> select repo -> existing YAML -> choose `.azure-pipelines.yml`
   - Enable scheduled triggers if required

How the script works (Standard)
- Discovers the current JSON link on the selected Microsoft download page, saves it under `scripts/ServiceTags` using the published filename, and selects only the requested service tag's prefixes:
  - [Commercial / Azure Public download](https://www.microsoft.com/en-us/download/details.aspx?id=56519): `ServiceTags_Public_*.json`
  - [Azure Government download](https://www.microsoft.com/en-us/download/details.aspx?id=57063): `ServiceTags_AzureGovernment_*.json`
- Fetches existing web config (az rest GET)
- Preserves existing non-auto rules; replaces rules named `ServiceTag_*` and legacy `AzureGov_LogicApps_USGovTX_*` rules, including when changing the selected tag
- Builds new allow rules with updated priorities
- PUTs merged ipSecurityRestrictions

How the script works (Consumption)
- Downloads and selects prefixes using the same service-tag flow; fails before updating Azure if the tag is missing or has no prefixes
- Retrieves existing workflow (GET) unless `-SkipFetchExisting`
- Constructs a full PUT body (PATCH not supported for workflow properties) adding / replacing `properties.accessControl`
- Always updates `triggers.allowedCallerIpAddresses`; adds `contents.allowedCallerIpAddresses` only if `-IncludeContentAccess` (preferred) or legacy `-Target Content|Both`
- Idempotence: skips PUT when existing sets already match (exact set comparison)

Caveats & recommendations
- For Consumption workflows the API version may change over time; script tries (user supplied, 2019-05-01, 2016-06-01).
- Use -WhatIf to preview changes; combine with -SkipFetchExisting if you only need the body template.
- Always validate the resulting access restrictions in the portal after first run.
- The pipeline uses a service principal; scope it to the resource group (least privilege).
- Consider fronting with API Management / Front Door for additional security layers.

Key script parameters
- `-LogicAppResourceId <id>`       Required
- `-ServiceTag <name>`             Exact service tag name in the selected cloud (default `LogicApps`)
- `-Cloud Commercial|Government`   Download feed and management endpoint (default `Commercial`)
- `-ApiVersion <version>`          Standard config API version (default 2021-02-01)
- `-Target Trigger|Content|Both`   Legacy selector (triggers always managed)
- `-IncludeContentAccess`          Adds `contents` block (Consumption)
- `-WhatIf`                        Preview only
- `-SkipFetchExisting`             Build body without initial GET (used with WhatIf)

Notes
- Standard mode uses PUT to `sites/<name>/config/web`.
- Consumption mode uses full workflow PUT (never PATCH) to add/replace `accessControl`.
- Set `includeContentAccess: true` in pipeline variables to manage both triggers and contents.

If desired, the script can be extended to emit an ARM template instead of performing the REST call.

## Running Locally

### Prerequisites
- PowerShell 7+ (`pwsh`) – Windows 10+ usually fine once PowerShell 7 is installed.
- Azure CLI 2.50+ (recommend latest). Verify with: `az version`.
- Network access to `https://www.microsoft.com/`, `https://download.microsoft.com/`, and the Azure management endpoint.
- Select `-Cloud Government` to use the Government feed and `https://management.usgovcloudapi.net`; Commercial uses `https://management.azure.com`. Authenticate Azure CLI (or the pipeline service connection) for the same cloud. The former `-ArmUrl` source override has been replaced by `-ServiceTag` and `-Cloud`.
- Appropriate RBAC on the target resource:
   - Standard: `Microsoft.Web/sites/config/Write` (e.g. Site Contributor / Contributor on the site or resource group).
   - Consumption: `Microsoft.Logic/workflows/Write` (Logic App Contributor / Contributor scope on RG or workflow).

### Authentication Options
1. Interactive user (Azure commercial):
    ```powershell
    az login
    az account set --subscription <SUBSCRIPTION_ID>
    ```
2. Interactive user (Azure Government):
    ```powershell
    az cloud set --name AzureUSGovernment
    az login
    az account set --subscription <SUBSCRIPTION_ID>
    ```
3. Service principal:
    ```powershell
    az login --service-principal -u <APP_ID> -p <CLIENT_SECRET> --tenant <TENANT_ID>
    az account set --subscription <SUBSCRIPTION_ID>
    ```

### Minimal Permissions
You can avoid full Contributor by assigning a custom role including only:
```
Microsoft.Web/sites/config/Read
Microsoft.Web/sites/config/Write
Microsoft.Logic/workflows/Read
Microsoft.Logic/workflows/Write
```
(Plus `Microsoft.Resources/subscriptions/resourceGroups/read`).

### Sample Commands
Preview (WhatIf) for a Consumption workflow (triggers + contents):
```powershell
pwsh ./scripts/patch-logicapp-access.ps1 `
   -LogicAppResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/TriggerTest" `
   -IncludeContentAccess -WhatIf
```

Apply (idempotent):
```powershell
pwsh ./scripts/patch-logicapp-access.ps1 -LogicAppResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/TriggerTest" -IncludeContentAccess
```

Standard (App Service / Logic App Standard plan) example:
```powershell
pwsh ./scripts/patch-logicapp-access.ps1 -LogicAppResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<siteName>" -ApiVersion 2021-02-01
```

Content-only legacy selection (still triggers always processed unless you omit IncludeContentAccess):
```powershell
pwsh ./scripts/patch-logicapp-access.ps1 -LogicAppResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/TriggerTest" -Target Content
```

Generate body without fetching existing (placeholder ID scenarios):
```powershell
pwsh ./scripts/patch-logicapp-access.ps1 -LogicAppResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/Placeholder" -WhatIf -SkipFetchExisting -IncludeContentAccess
```

Select a regional service tag:
```powershell
pwsh ./scripts/patch-logicapp-access.ps1 -LogicAppResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/TriggerTest" -ServiceTag "LogicApps.EastUS" -WhatIf
```

Select Azure Government and a Government regional service tag:
```powershell
az cloud set --name AzureUSGovernment
az login
pwsh .\scripts\patch-logicapp-access.ps1 -LogicAppResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Logic/workflows/TriggerTest" -Cloud Government -ServiceTag "LogicApps.USGovTexas" -WhatIf
```

### Idempotence Behavior
If both trigger and (when selected) contents IP lists already match the resolved prefixes (set comparison), the script skips the PUT and prints existing counts.

### Troubleshooting
- Missing tag or empty prefix list: verify the exact tag name and its `properties.addressPrefixes` in the downloaded JSON. Wildcards are not supported; no other tags are used as a fallback.
- 401 / 403 errors: ensure you logged in to correct subscription and have write permission.
- Logic App not updating (Consumption): confirm there are no deployment locks and that the workflow is in Enabled state.
- To view current access control after run:
   ```powershell
   az rest --method get --uri "https://management.azure.com/<resourceId>?api-version=2019-05-01" | ConvertFrom-Json | Select -Expand properties | Select -Expand accessControl
   ```
   For Government, replace `https://management.azure.com` with `https://management.usgovcloudapi.net`.

### Regression Tests
With Pester available, run the download discovery and prefix-selection tests (network and Azure CLI calls are mocked):
```powershell
Invoke-Pester -Script .\scripts\tests\patch-logicapp-access.Tests.ps1
```

### Optional Isolation
Set a custom Azure CLI profile directory if you want to isolate credentials:
```powershell
$env:AZURE_CONFIG_DIR = "$HOME/.azure-iprange-updater"
az login
```
