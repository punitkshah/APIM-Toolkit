# Azure API Management Credential Inventory & Rotation Toolkit

A single PowerShell script for Azure API Management (APIM) that helps you:

- **Find where credentials live**: subscription keys, named values, backends, OAuth 2.0 / OpenID Connect providers and loggers. This is read-only.
- **Rotate subscription keys in bulk**: you see a preview and must type a confirmation before any key changes.

Reports show *where* each credential is stored (Key Vault, APIM, a literal value or managed identity). They never contain secret values.

---

## Quick start: read-only inventory

**1. Open a PowerShell session.** The easiest option is [Azure Cloud Shell](https://shell.azure.com) in PowerShell mode, where you are already signed in. To run locally, use PowerShell 5.1 or 7+ and install the Az module once:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
```

**2. Download and run the script.**

```powershell
git clone https://github.com/punitkshah/APIM-Toolkit.git
cd APIM-Toolkit
./Invoke-ApimCredentialToolkit.ps1 -Action InventoryAll -SkipSecretPresenceCheck
```

The script signs you in if needed. If your Azure subscription has more than one APIM instance, it lists them so you can choose one.

**3. Open the results.** The script prints the report folder path. Start with `<instance>_summary.csv` (for example, `contoso-apim_summary.csv`), which has one row per area with an item count and status. If any status shows `FAILED`, check `run.log` in the same folder for details.

Nothing in Azure changes, and the **Reader** role on the APIM instance is enough.

**Tips**

- To use the interactive menu, run `./Invoke-ApimCredentialToolkit.ps1` without parameters.
- To skip the instance list, add `-ResourceGroup <rg> -ApimName <name>`.
- If APIM is in a different Azure subscription, add `-SubscriptionId <azure-subscription-id>`.

---

## Rotate subscription keys without downtime

Each APIM subscription has a **primary** and a **secondary** key. Rotate one key at a time so clients always have a working key.

> [!WARNING]
> A regenerated key stops working immediately. Clients still using it receive `401 Unauthorized`. This toolkit does not send new keys to clients. Test in a non-production instance first.

You need the **API Management Service Contributor** role.

1. **Move clients to the primary key.** Ask every client to call APIM with its primary key.
2. **Preview the secondary key rotation.**

   ```powershell
   ./Invoke-ApimCredentialToolkit.ps1 -Action RegenerateSecondaryKeys
   ```

   The script lists the subscriptions it would change and saves them to `<instance>_secondary_selected_<timestamp>.csv`. To cancel without changing anything, press **Enter** at the prompt.
3. **Regenerate the secondary keys.** Run the same command again. When prompted, type the APIM instance name.
4. **Move clients to the new secondary key.** Share the new key, for example from **APIM > Subscriptions** in the Azure portal, and confirm that clients use it.
5. **Rotate the primary keys.** Repeat steps 2–3 with `-Action RegeneratePrimaryKeys`.

**Limit which subscriptions are rotated**

| Goal | Add |
|---|---|
| Only subscriptions whose ID or display name matches a pattern | `-SubscriptionFilter 'partner-*'` |
| Skip the built-in all-access subscription | `-ExcludeBuiltInAllAccess` |
| Only the IDs listed in a file | `-SubscriptionListFile <file>` (a CSV with a `Sid` column, or one ID per line) |

**If some keys fail**, the script saves the failed subscriptions to `<instance>_<primary|secondary>_failed_<timestamp>.csv` and shows the command to retry only those subscriptions:

```powershell
./Invoke-ApimCredentialToolkit.ps1 -Action RegenerateSecondaryKeys `
  -SubscriptionListFile ./apim-credential-reports/<folder>/<instance>_secondary_failed_<timestamp>.csv
```

> [!NOTE]
> List files match only the APIM subscription ID (`Sid`). If the same ID exists in several workspaces, all of them are selected. Before you confirm, check the `InstanceScope` column in the preview.

**If a run is interrupted**, a key may have changed even if no result was saved for it. Before you retry, treat every subscription in the `_selected_` CSV as possibly rotated.

**In a pipeline**, add `-Force` to skip the confirmation prompt. Use it only with a filter or list you have already previewed. See [Exit codes](#exit-codes).

---

## Rotate other credentials

The inventory shows where each credential is stored. Rotate each one at its source:

- **Key Vault named values**: Rotate the secret in Key Vault. APIM uses the new version when it refreshes the reference.
- **Secrets stored in APIM or as literal values**: Rotate at the source, update APIM, and consider moving them to Key Vault named values.
- **OAuth 2.0 / OpenID Connect client secrets**: Create a new secret at the identity provider (for example, a Microsoft Entra app registration), update APIM, test, then delete the old secret.
- **Event Hubs loggers**: Rotate the shared access key you are not using, update the referenced named value, then rotate the other key. Use managed identity where possible.

---

## Reference

### What each inventory checks

| Menu | `-Action` | Lists |
|---|---|---|
| 1 | `InventorySubscriptionKeys` | Every subscription at service and workspace level, with scope, state, owner and dates. The built-in all-access subscription is flagged. |
| 2 | `InventoryNamedValues` | Secret named values, whether each is stored in APIM or Key Vault, and plain-text values that look like secrets |
| 3 | `InventoryBackends` | Backend headers, query parameters, authorization, client certificates and proxy passwords, plus APIM certificates with days until expiry |
| 4 | `InventoryOAuth` | OAuth 2.0 authorization servers, OpenID Connect providers and credential manager providers, including whether a client secret is set |
| 5 | `InventoryLoggers` | Event Hubs and Application Insights loggers, and whether each uses a connection string, an instrumentation key or managed identity |
| 6 | `InventoryAll` | Runs 1–5 and writes a summary |
| 7 | `RegeneratePrimaryKeys` | **Changes keys.** Regenerates primary keys after a preview and confirmation. |
| 8 | `RegenerateSecondaryKeys` | **Changes keys.** Regenerates secondary keys after a preview and confirmation. |

The menu also has **S** (switch instance), **H** (rotation guide) and **Q** (quit).

### Permissions

| Task | Minimum role on the APIM instance |
|---|---|
| Inventories with `-SkipSecretPresenceCheck` | **Reader** |
| Inventory 4 without `-SkipSecretPresenceCheck` | **API Management Service Contributor**. The script calls `listSecrets`, checks the result in memory and reports only whether a secret is set. |
| Regenerate keys (7, 8) | **API Management Service Contributor**, or a custom role with `Microsoft.ApiManagement/service/subscriptions/regeneratePrimaryKey/action` and `.../regenerateSecondaryKey/action` |

### Parameters

| Parameter | Description | Default |
|---|---|---|
| `-Action` | Run one action and exit. See the table above. | Interactive menu |
| `-SubscriptionId` | Azure subscription that contains the APIM instance. This is not an APIM subscription. | Current Az context |
| `-ResourceGroup` | Resource group of the APIM instance | Choose from a list |
| `-ApimName` | APIM instance name | Choose from a list |
| `-SubscriptionFilter` | Wildcard pattern for the APIM subscription ID or display name to rotate | `*` |
| `-SubscriptionListFile` | CSV file with a `Sid` column, or a text file with one APIM subscription ID per line | – |
| `-ExcludeBuiltInAllAccess` | Skip the built-in all-access (`master`) subscription | Off |
| `-Force` | Skip the confirmation prompt before regeneration | Off |
| `-SkipSecretPresenceCheck` | Do not call `listSecrets` on OAuth 2.0 / OpenID Connect providers | Off |
| `-OutputPath` | Root folder for reports | `./apim-credential-reports` |
| `-DelayMs` | Pause between regeneration calls, to avoid throttling | `250` |
| `-ApiVersion` | Microsoft.ApiManagement ARM API version | `2024-05-01` |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | No fatal error. A rotation also returns `0` if you cancel or no subscriptions match. `InventoryAll` can return `0` even when a section fails. |
| `1` | Error: sign-in failed, the instance wasn't found, permission was denied, or an unexpected failure occurred |
| `2` | Regeneration finished, but one or more subscriptions failed |

In automation, `0` alone does not prove the work was done. For inventories, check `<instance>_summary.csv`. For rotations, compare the `_selected_` and `_regeneration_results_` CSVs.

### Output files

Each run creates a folder: `apim-credential-reports/<instance>_<yyyyMMdd_HHmmss>/`. Every CSV name starts with the APIM instance name, so you can collect reports from several instances in one place and still tell them apart. A section with no items does not create a CSV.

| File | Contents |
|---|---|
| `<instance>_summary.csv` | Item count and status per area (`InventoryAll` only) |
| `<instance>_subscription_keys.csv` | Subscription inventory |
| `<instance>_named_values_secrets.csv` | Secret named values and where they are stored |
| `<instance>_backend_credentials.csv` | Backend credentials and their value source |
| `<instance>_certificates.csv` | Certificates with expiry date and days remaining |
| `<instance>_oauth_openid_secrets.csv` | OAuth 2.0, OpenID Connect and credential manager providers |
| `<instance>_logger_credentials.csv` | Logger authentication method and credential source |
| `<instance>_<primary\|secondary>_selected_<ts>.csv` | Subscriptions selected for rotation, saved before any change |
| `<instance>_<primary\|secondary>_regeneration_results_<ts>.csv` | Result for each subscription, added during the run |
| `<instance>_<primary\|secondary>_failed_<ts>.csv` | Failed subscriptions only. Use with `-SubscriptionListFile` to retry. |
| `run.log` | Time-stamped log of the run |

For example, after a full inventory and a secondary key rotation of `contoso-apim`:

```text
apim-credential-reports/
└── contoso-apim_20261123_101500/
    ├── contoso-apim_summary.csv
    ├── contoso-apim_subscription_keys.csv
    ├── contoso-apim_named_values_secrets.csv
    ├── contoso-apim_backend_credentials.csv
    ├── contoso-apim_certificates.csv
    ├── contoso-apim_oauth_openid_secrets.csv
    ├── contoso-apim_logger_credentials.csv
    ├── contoso-apim_secondary_selected_20261123_102030.csv
    ├── contoso-apim_secondary_regeneration_results_20261123_102030.csv
    ├── contoso-apim_secondary_failed_20261123_102030.csv
    └── run.log
```

Reports contain **no secret values**, but they do include resource names, client IDs and endpoints. Keep them internal and out of source control. This repository already ignores `apim-credential-reports/`. If you copy the script elsewhere, add that folder to your `.gitignore`.

### Built-in safeguards

- **Confirmation**: before regenerating keys, you must type the instance name. `-Force` skips this step.
- **Retries**: throttling (429) and transient server errors (5xx) are retried with back-off, and `Retry-After` is honored.
- **Complete coverage**: every list call is paged, and service-level and workspace-level items are included.
- **Unsupported features are skipped**: if your tier doesn't support a feature, such as workspaces, that section is skipped and the rest of the run continues.
- **Clear errors**: an expired sign-in (401) or missing permission (403) produces a readable message.

### Notes and limitations

- Works with Classic tiers (Developer, Basic, Standard, Premium, Consumption) and v2 tiers.
- Uses the Azure Resource Manager REST API through `Invoke-AzRestMethod`, so it works in whichever Azure cloud you're signed in to (public or sovereign).
- Does not cover self-hosted gateway tokens, Management API access keys or Git configuration access.

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
