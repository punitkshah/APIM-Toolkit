# Azure API Management Credential Inventory & Rotation Toolkit

A menu-driven PowerShell toolkit that **finds every credential in an Azure API Management (APIM) instance** and **regenerates subscription keys in bulk**, with confirmation, retries and a CSV report for every run.

Use it to answer two questions quickly:

1. *Where are all the secrets in my APIM instance, and where do they live?*
2. *How do I rotate every subscription key safely, without doing it one at a time in the portal?*

> **Secret values are never printed or written to disk.** The inventories report *where* each credential lives (Key Vault, named value, literal value, managed identity) so you can plan rotation.

---

## Features

| # | Option | What it does |
|---|---|---|
| 1 | **Subscription keys** | Lists every subscription (service level and workspaces) with scope, state, owner, created/expiry dates, and flags the built-in all-access subscription |
| 2 | **Named values holding secrets** | Lists secret named values, shows whether each is stored in APIM or referenced from Azure Key Vault (identity and last sync status), and flags plain-text values that *look* like secrets |
| 3 | **Backend credentials** | Lists backend headers, query parameters, authorization headers, client certificates and proxy passwords, and whether each value comes from a named value or is a literal. Also lists APIM certificates with days to expiry |
| 4 | **OAuth 2.0 / OpenID Connect client secrets** | Lists authorization servers, OpenID Connect providers and credential manager providers, and whether a client secret is configured (checked without reading it out) |
| 5 | **Logger connection strings** | Lists Event Hubs and Application Insights loggers and whether they use a connection string, instrumentation key or managed identity |
| 6 | **Full credential report** | Runs options 1–5 and writes a summary |
| 7 | **Regenerate PRIMARY subscription keys** | Collects all subscription IDs, saves the list, asks for confirmation, then regenerates the primary key for each |
| 8 | **Regenerate SECONDARY subscription keys** | Same as 7, for the secondary key |

Plus: **S** switch instance, **H** rotation guide, **Q** quit.

### Built for safe, unattended use

- **Typed confirmation** before any key changes (type the instance name), with a clear warning about which clients will break. `-Force` skips it for pipelines.
- **Automatic retry** with back-off for throttling (HTTP 429) and transient errors (5xx), honouring `Retry-After`.
- **Full paging** of every list call, and **workspace-aware**: service-level and workspace-level items are both covered.
- **Graceful degradation**: if a feature is not available on your tier (for example workspaces or credential manager), that section is skipped and the rest continues.
- **Crash-safe results**: each regeneration result is appended to CSV immediately, so an interruption never loses the record.
- **Targeted retries**: failures are written to their own CSV, which you can feed straight back in with `-SubscriptionListFile`.
- **Filtering**: limit regeneration with a wildcard (`-SubscriptionFilter 'partner-*'`) or exclude the built-in all-access subscription.
- **Friendly errors** for expired sign-in (401) and missing permissions (403).
- Shows the instance tier and whether it is **Classic** or **v2**.

---

## Prerequisites

- **PowerShell 5.1** or **PowerShell 7+** (Windows, macOS, Linux), or **Azure Cloud Shell** (works out of the box)
- **Az.Accounts** module (provides `Invoke-AzRestMethod`)

  ```powershell
  Install-Module Az.Accounts -Scope CurrentUser
  ```

### Permissions

| Task | Minimum role on the APIM instance |
|---|---|
| Inventories 1–3, 5 | **Reader** |
| Inventory 4 – "client secret set?" check | **API Management Service Contributor** (needs `listSecrets`). Use `-SkipSecretPresenceCheck` with Reader only |
| Options 7 and 8 – regenerate keys | **API Management Service Contributor**, or a custom role with `Microsoft.ApiManagement/service/subscriptions/regeneratePrimaryKey/action` and `.../regenerateSecondaryKey/action` |

---

## Quick start

```powershell
# 1. Download the script
git clone https://github.com/<your-account>/<your-repo>.git
cd <your-repo>

# 2. Run it – signs you in if needed, lets you pick an instance, shows the menu
./Invoke-ApimCredentialToolkit.ps1
```

In **Azure Cloud Shell**, upload `Invoke-ApimCredentialToolkit.ps1` and run the same command; you are already signed in.

```
  ================================================================
   Azure API Management - Credential Inventory and Rotation Toolkit
  ================================================================
   Instance : contoso-apim   (resource group: rg-apim)
   Tier     : Premium (Classic)   Region: uaenorth
   Reports  : ./apim-credential-reports/contoso-apim_20261123_010000

   INVENTORY (read-only)
     1  Subscription keys
     2  Named values holding secrets
     3  Backend credentials (headers, query parameters, client certificates)
     4  OAuth 2.0 / OpenID Connect client secrets
     5  Logger connection strings (Event Hubs, Application Insights)
     6  Full credential report (runs 1-5)

   ROTATION (changes keys)
     7  Regenerate PRIMARY subscription keys
     8  Regenerate SECONDARY subscription keys

     S  Switch APIM instance      H  Rotation guide      Q  Quit
```

---

## Non-interactive examples

```powershell
# Full credential report for one instance
./Invoke-ApimCredentialToolkit.ps1 -ResourceGroup rg-apim -ApimName contoso-apim -Action InventoryAll

# Instance in a different Azure subscription
./Invoke-ApimCredentialToolkit.ps1 -SubscriptionId <azure-subscription-id> -ResourceGroup rg-apim -ApimName contoso-apim -Action InventoryNamedValues

# Regenerate SECONDARY keys for a subset, skipping the built-in all-access subscription
./Invoke-ApimCredentialToolkit.ps1 -ResourceGroup rg-apim -ApimName contoso-apim `
  -Action RegenerateSecondaryKeys -SubscriptionFilter 'partner-*' -ExcludeBuiltInAllAccess

# Retry only the subscriptions that failed in a previous run
./Invoke-ApimCredentialToolkit.ps1 -ResourceGroup rg-apim -ApimName contoso-apim `
  -Action RegenerateSecondaryKeys -SubscriptionListFile ./apim-credential-reports/<folder>/secondary_failed_<timestamp>.csv

# Pipeline / automation (no prompt)
./Invoke-ApimCredentialToolkit.ps1 -ResourceGroup rg-apim -ApimName contoso-apim `
  -Action RegeneratePrimaryKeys -Force
```

---

## Parameters

| Parameter | Description | Default |
|---|---|---|
| `-SubscriptionId` | Azure subscription that holds the APIM instance | Current Az context |
| `-ResourceGroup` | Resource group of the APIM instance | Pick from list |
| `-ApimName` | APIM instance name | Pick from list |
| `-Action` | Run one action and exit: `InventorySubscriptionKeys`, `InventoryNamedValues`, `InventoryBackends`, `InventoryOAuth`, `InventoryLoggers`, `InventoryAll`, `RegeneratePrimaryKeys`, `RegenerateSecondaryKeys` | Interactive menu |
| `-SubscriptionFilter` | Wildcard on subscription ID or display name, for regeneration | `*` |
| `-SubscriptionListFile` | CSV with a `Sid` column, or a text file with one ID per line, to target specific subscriptions | – |
| `-ExcludeBuiltInAllAccess` | Skip the built-in all-access (`master`) subscription | Off |
| `-Force` | Skip the typed confirmation before regeneration | Off |
| `-SkipSecretPresenceCheck` | Do not call `listSecrets` on OAuth / OpenID Connect providers | Off |
| `-OutputPath` | Root folder for reports | `./apim-credential-reports` |
| `-DelayMs` | Pause between regeneration calls (throttling protection) | `250` |
| `-ApiVersion` | Microsoft.ApiManagement ARM API version | `2024-05-01` |

### Exit codes (non-interactive mode)

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error (sign-in, instance not found, permissions, unexpected failure) |
| `2` | Regeneration finished, but one or more subscriptions failed |

---

## Output

Each run creates a time-stamped folder: `apim-credential-reports/<instance>_<yyyyMMdd_HHmmss>/`

| File | Contents |
|---|---|
| `0_summary.csv` | Counts per area (full report) |
| `1_subscription_keys.csv` | Subscription inventory |
| `2_named_values_secrets.csv` | Secret named values and where they are stored |
| `3_backend_credentials.csv` | Backend credentials and their value source |
| `3_certificates.csv` | Certificates with expiry and days remaining |
| `4_oauth_openid_secrets.csv` | OAuth 2.0 / OpenID Connect / credential manager providers |
| `5_logger_credentials.csv` | Logger authentication method and credential source |
| `<primary\|secondary>_selected_<ts>.csv` | Subscriptions selected for regeneration (before any change) |
| `<primary\|secondary>_regeneration_results_<ts>.csv` | Result per subscription, written as it runs |
| `<primary\|secondary>_failed_<ts>.csv` | Failures only – use with `-SubscriptionListFile` to retry |
| `run.log` | Time-stamped log of the run |

> Reports contain **no secret values**, but they do contain resource names, client IDs and endpoints. Treat them as internal and keep them out of source control (see `.gitignore` below).

---

## Recommended rotation sequence

### Subscription keys (zero downtime)

1. Run **option 1** to record the current subscriptions.
2. Ask every client to use the **primary** key.
3. Run **option 8** to regenerate **secondary** keys.
4. Give clients the new **secondary** key and confirm they use it.
5. Run **option 7** to regenerate **primary** keys.

### Other credentials

- **Key Vault named values** – rotate the secret in Key Vault; APIM picks up the new version when it refreshes the reference.
- **Secrets stored in APIM / literal values** – rotate at the source, update APIM, and move them to Key Vault named values.
- **OAuth 2.0 / OpenID Connect client secrets** – create a new secret at the identity provider (for example the Microsoft Entra app registration), update APIM, test, then delete the old secret.
- **Event Hubs loggers** – rotate the shared access key you are not using, update the referenced named value, then rotate the other key. Prefer managed identity where possible.

---

## Suggested `.gitignore`

```gitignore
# Toolkit reports – contain resource metadata
apim-credential-reports/
```

---

## Notes and limitations

- Works with Classic (Developer, Basic, Standard, Premium, Consumption) and v2 tiers. Features not available on a tier are skipped automatically.
- The script uses the Azure Resource Manager REST API (`Invoke-AzRestMethod`), so it follows your current Azure cloud (public or sovereign).
- Inventories are read-only. Only options 7 and 8 change anything.
- Subscription key regeneration takes effect immediately. Any client still using the old key will receive `401 Unauthorized`.
- Self-hosted gateway tokens, the Management API access keys and Git configuration access are not covered.
- **Always test in a non-production instance first.**

---

## References

- [Subscriptions in Azure API Management](https://learn.microsoft.com/azure/api-management/api-management-subscriptions)
- [Subscription – Regenerate Primary Key (REST API)](https://learn.microsoft.com/rest/api/apimanagement/subscription/regenerate-primary-key)
- [Subscription – Regenerate Secondary Key (REST API)](https://learn.microsoft.com/rest/api/apimanagement/subscription/regenerate-secondary-key)
- [Use named values in Azure API Management policies](https://learn.microsoft.com/azure/api-management/api-management-howto-properties)
- [Secure your Azure API Management deployment](https://learn.microsoft.com/security/benchmark/azure/baselines/api-management-security-baseline)

---

## Contributing

Issues and pull requests are welcome. Please do not include secret values, subscription keys or report files in issues or pull requests.

## Disclaimer

This is a community sample, **not an official Microsoft product**, and is provided **"as is"** without warranty of any kind. Review the script and test it in a non-production environment before use. You are responsible for any changes made to your Azure resources.

## License

[MIT](LICENSE)
