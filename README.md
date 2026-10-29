# Assigning Extended Security Updates (ESU) to Azure Arc-enabled Windows Server 2016 using PowerShell and REST

Updated October 29, 2026.

An Azure Arc-enabled Windows Server 2016 machine can be linked to an existing Windows Server 2016 ESU license through Azure Resource Manager. This guide updates the approach in [my Windows Server 2012 walkthrough](https://jpigott.com/2023/09/assigning-extended-service-updates-esu-to-an-azure-arc-enabled-windows-server-2012/), using the [Windows Server 2016 programmatic deployment guidance on Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates?pivots=windows-server-2016).

The samples assume that you have already created and activated an appropriately sized ESU license in the Azure portal. The scripts folder contains only your original single-machine script and a self-contained CSV assignment script. They do not onboard servers, purchase or activate licenses, calculate licensing entitlements, or install updates.

> **Timing:** Windows Server 2016 reaches end of support on January 12, 2027. Microsoft Learn states that ESU configuration is available starting August 3, 2026, and Arc ESU billing begins January 13, 2027. Preparing an assignment before then does not demonstrate that a future ESU update can be installed. See [Prepare delivery](https://learn.microsoft.com/en-us/azure/azure-arc/servers/prepare-extended-security-updates?pivots=windows-server-2016).

## What changes from the Windows Server 2012 example?

| Area | Windows Server 2016 guidance |
| --- | --- |
| License target | Must be `Windows Server 2016`; do not reuse a 2012/R2 license. |
| Connected Machine agent | Version **1.62 or later**, rather than the 2012 minimum of 1.34. |
| Editions | Standard and Datacenter are supported. |
| Core selection | The 2016 portal workflow selects physical or virtual cores when enabling ESUs on machines, not when creating the license. See the API limitation below. |
| Volume Licensing transition | Transition from Volume Licensing to Arc ESUs is not supported for 2016. |
| No-cost exceptions | Do not carry over the 2012 Visual Studio dev/test or disaster recovery benefit tags; those no-cost benefits are not available for 2016. |
| Authentication | The CSV script uses `Az.Accounts`; the original single-machine script retains its OAuth client-credentials/REST approach. This is an implementation choice, not a WS2016 requirement. |
| Authorization | Onboarding permission alone is not sufficient evidence of license-management permission. Grant the relevant license/profile actions. |

### Important documentation gap: physical versus virtual core selection

The [2016 portal enrollment guide](https://learn.microsoft.com/en-us/azure/azure-arc/servers/deliver-extended-security-updates?pivots=windows-server-2016) explicitly asks for a core type when enabling a machine. However, the supplied [programmatic guide](https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates?pivots=windows-server-2016) shows only `assignedLicense` in the link request, and the [2026-09-01 REST request schema](https://learn.microsoft.com/en-us/rest/api/hybridcompute/license-profiles/create-or-update?view=rest-hybridcompute-2026-09-01) likewise does not document a writable ESU core-type field.

These samples follow the published programmatic request exactly; **they do not invent a core-type property or claim to automate that portal selection**. Before broad deployment, pilot a representative server, confirm the intended core basis and entitlement in the portal, and obtain current Microsoft guidance if the API assignment does not establish the required core choice. Use the portal's **Enable ESUs** workflow when an explicit physical/virtual selection is required. A successful REST assignment alone is not proof of compliant core licensing.

## Prerequisites

1. Connect the Windows Server 2016 machines to Azure Arc and confirm that their status is **Connected**. Install Connected Machine agent **1.62 or later**.
2. Verify eligibility, Software Assurance/SPLA/server subscription requirements, licensing edition, and sufficient licensed cores with your licensing administrator. Review [license provisioning guidelines](https://learn.microsoft.com/en-us/azure/azure-arc/servers/license-extended-security-updates?pivots=windows-server-2016). Physical licensing has a minimum of 16 cores per machine; virtual licensing has a minimum of eight cores per VM and uses Standard ESU licensing, even for Datacenter guests. Virtual-core licensing cannot cover a physical server. These scripts do not calculate coverage or check all eligibility conditions.
3. In **Azure Arc > Licenses > Windows Server 2016 ESU licenses**, create or select the correct license and ensure its status is **Activated**. Complete the required licensing attestation. Copy its full **Resource ID**. The license resource group may differ from the machine resource group.
4. Configure Arc connectivity, required certificate authorities, and your update infrastructure as described in [Prepare delivery](https://learn.microsoft.com/en-us/azure/azure-arc/servers/prepare-extended-security-updates?pivots=windows-server-2016). ESU enrollment does not configure WSUS, Microsoft Update, Configuration Manager, or Azure Update Manager.
5. Run the scripts from an administration workstation or automation host with Windows PowerShell 5.1 or PowerShell 7. The CSV script additionally requires `Az.Accounts`; your original single-machine REST script does not. They need not run on the target server. These samples intentionally support **Azure public cloud**. For the CSV script, machine/license IDs must be in the **currently selected subscription**. Cross-subscription assignment is outside this sample's scope.

### Azure RBAC

For these scripts, the calling identity needs:

| Scope | Required operations |
| --- | --- |
| Target Arc machine(s) | `Microsoft.HybridCompute/machines/read`, `Microsoft.HybridCompute/machines/licenseProfiles/read`, `Microsoft.HybridCompute/machines/licenseProfiles/write` |
| Selected ESU license(s) | `Microsoft.HybridCompute/licenses/read` |

A custom role can limit access to these operations. **Contributor** scoped to the relevant resource groups is a broader alternative, subject to your organization's policies. If machine and license resources are in different groups, grant access at both appropriate scopes. License creation or activation requires additional permissions, including `Microsoft.HybridCompute/licenses/write`, and is not performed here.

**Azure Connected Machine Resource Administrator** at the relevant resource-group scope is an appropriate built-in role. Subscription-wide access is not required. **Azure Connected Machine Onboarding** alone does not grant license-profile writes. Review the [current built-in role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/management-and-governance#azure-connected-machine-resource-administrator) and applicable deny assignments/policies.

## 1. Sign in

Install the prerequisite once if needed:

```powershell
Install-Module Az.Accounts -Scope CurrentUser -Repository PSGallery
Import-Module Az.Accounts
Connect-AzAccount -Tenant '<tenant-guid>'
Set-AzContext -SubscriptionId '<subscription-guid>'
```

For unattended execution, use an approved managed identity, workload identity, or certificate-based service principal. For example, on an Azure automation host that supports managed identity:

```powershell
Connect-AzAccount -Identity
Set-AzContext -SubscriptionId '<subscription-guid>'
```

Assign that identity the required RBAC access first. Managed identity authentication is an alternative to interactive sign-in, not an additional step. Do not embed client secrets in scripts or CSV files.

## 2. Identify the resources

From the folder containing this guide, substitute your actual values:

```powershell
$subscriptionId = '<subscription-guid>'
$machineId = "/subscriptions/$subscriptionId/resourceGroups/rg-arc-servers/providers/Microsoft.HybridCompute/machines/WS2016-01"
$licenseId = "/subscriptions/$subscriptionId/resourceGroups/rg-esu-licenses/providers/Microsoft.HybridCompute/licenses/ws2016-esu"
```

Use the **Arc resource name**, which is not necessarily the guest's hostname. The scripts obtain the region from the Arc machine, rather than assuming it is the license's region.

## 3. Link one machine with the original script

Your original `scripts\WS2016_ESU_License.ps1` is unchanged. Configure its tenant,
application credentials, subscription, resource group, server, license name, and
machine location before running it. Ensure its Authorization header uses
`"Bearer $token"`. Do not publish a populated secret or token.

```powershell
.\scripts\WS2016_ESU_License.ps1
```

This original script sends the assignment directly; it does not provide the CSV
script's preflight checks, `-WhatIf`, replacement protection, or read-back loop.
It assumes the machine and license are in the same resource group. If they
differ, use the license's resource group in `assignedLicense`.

The request follows Microsoft Learn:

```http
PUT https://management.azure.com{machineResourceId}/licenseProfiles/default?api-version=2023-06-20-preview
Content-Type: application/json
Authorization: Bearer <managed-by-Az.Accounts>
```

```json
{
  "location": "<region-read-from-the-Arc-machine>",
  "properties": {
    "esuProfile": {
      "assignedLicense": "<full-ESU-license-resource-ID>"
    }
  }
}
```

The original single-machine script and the CSV script's profile creation request
use the **preview API version in the supplied ESU guide**. For an existing
profile, the CSV script uses the documented **PATCH API version 2026-09-01** to
update only `properties.esuProfile.assignedLicense`. See
[License Profiles - Update](https://learn.microsoft.com/en-us/rest/api/hybridcompute/license-profiles/update?view=rest-hybridcompute-2026-09-01).
The PATCH body omits `location`, tags, Software Assurance, and product settings;
it does not copy read-only response fields into the request. This preserves
unrelated settings instead of blocking assignment merely because they exist.
If the profile does not exist, the script creates it with the original PUT
payload shown above. The core-type documentation gap remains unchanged.

After submission, the **CSV script** reads back the profile up to 12 times, with five seconds between reads, and reports `Linked` only when `assignedLicense` matches. If it already matches, it reports `AlreadyLinked` without a write. A timeout explicitly states that a request was submitted but not verified; inspect the current state before retrying.

The CSV script never writes to the parent machine resource. Existing-profile
assignment updates use the targeted PATCH, rather than a replacement PUT.

## 4. Link a reviewed list of machines

### Simple CSV of machine names

`scripts\WS2016_ESU_License_CSV.ps1` accepts a `MachineName` column and assigns
one existing license to every listed machine in the specified resource group.
Your original `scripts\WS2016_ESU_License.ps1` remains unchanged. The CSV version
includes its own validated linking functions and uses `Az.Accounts` authentication,
rather than copying a client secret into the new file.

Edit `examples\machine-names.csv` using the **Azure Arc resource names**:

```csv
MachineName
WS2016-01
WS2016-02
```

`-CsvPath` is optional: by default the script loads
`examples\machine-names.csv` from the repository/deployment folder, located
relative to the script itself rather than the current working directory.
Keep the `scripts` and `examples` folder layout when copying it to another host.
The script prints the resolved CSV path before authentication and preflight.

With `-AuthenticationMode Interactive`, omitting `-CsvPath` displays a prompt
such as:

```text
CSV path [C:\Scripts\examples\machine-names.csv] (press Enter to accept):
```

Press **Enter** to accept the displayed path, or type another path. Supplying
`-CsvPath` skips this prompt. `ServicePrincipal` and `ExistingContext` modes
never prompt for the CSV path, so unattended runs remain noninteractive.

To use another file, supply `-CsvPath "C:\ESU Inputs\machines.csv"`.
Normal PowerShell command-line quotes are valid and required for paths with
spaces; they are not part of the resulting value. If quotes were pasted into a
parameter value (for example, from a prompt or automation variable), the script
removes one matching pair of surrounding single or double quotes. Unmatched
quotes produce an explicit error. Explicit relative paths are still relative
to your current working directory.

Sign in and select the subscription as described above, then preview:

```powershell
$parameters = @{
    SubscriptionId = '<subscription-guid>'
    ResourceGroupName = 'ArcDemoLab'
    EsuLicenseName = 'WS2016ESUDemo'
}
.\scripts\WS2016_ESU_License_CSV.ps1 @parameters -WhatIf
```

Run the assignments after reviewing the preview:

```powershell
.\scripts\WS2016_ESU_License_CSV.ps1 @parameters
```

The CSV script supports both individual use and unattended automation:

| AuthenticationMode | Behavior |
| --- | --- |
| `ExistingContext` (default) | Uses the existing `Connect-AzAccount` session; no sign-in prompt is initiated by the script. |
| `Interactive` | Signs in a person for the specified tenant and subscription. |
| `ServicePrincipal` | Signs in unattended with the supplied application ID and secret; never falls back to interactive sign-in. |

**Which identity is used?** `ExistingContext` reads the current `Az.Accounts`
context (`Get-AzContext`), which can have been restored from an earlier Azure
sign-in. It is not necessarily your Windows account and might be a service
principal rather than a person. The script now prints the account ID/type,
tenant, subscription, and authentication mode before its permission preflight.
It pins that context for the run; it never prints a token or secret.

Before any license assignments, the CSV script queries the Azure Authorization
[caller permissions API](https://learn.microsoft.com/en-us/rest/api/authorization/permissions/list-for-resource?view=rest-authorization-2022-04-01)
at the license, each machine, and each machine's license profile. It checks
license read, machine read, and profile read/write actions, accounting for
wildcard grants and each grant's `NotActions`. It also reads all target machines,
their profiles, and the license to detect actual read failures before any writes.
If any target lacks a required action, it stops with the identity, action, scope,
and guidance to use the authorized service principal or request the correct role.

This preflight runs with `-WhatIf` too. A failure to inspect permissions stops the
run explicitly; it is not misreported as proof that the ESU operation is denied.
The caller must be able to query its permissions at these scopes; if that API
returns an authorization error, have an administrator review the identity's
`Microsoft.Authorization/permissions/read` access as well.
The check is not a guarantee of a future write: deny assignments, conditions,
policy, PIM activation, role propagation, or access changes can still cause Azure
to reject a request. Ordinary per-request error handling remains in place.

For an individual operator, the script can handle sign-in:

```powershell
.\scripts\WS2016_ESU_License_CSV.ps1 @parameters `
    -AuthenticationMode Interactive `
    -TenantId '<tenant-guid>' `
    -WhatIf
```

For a manual run using a service principal, **run this first in the same
PowerShell session** to enter the secret securely:

```powershell
$secret = Read-Host 'New service principal secret' -AsSecureString
```

Then pass `$secret` to the script using the `$parameters` configuration above:

```powershell
.\scripts\WS2016_ESU_License_CSV.ps1 @parameters `
    -AuthenticationMode ServicePrincipal `
    -TenantId '<tenant-guid>' `
    -ClientId '<application-client-guid>' `
    -ClientSecret $secret `
    -Confirm:$false
```

`-ClientSecret` requires a `SecureString`; a quoted plaintext value will fail
parameter binding. Never paste the secret into the command itself, source code,
or chat. If a secret has been exposed, revoke it and create a replacement first.
The `Read-Host` step is for manual runs only, not unattended execution.

For unattended automation, retrieve the secret from your approved secret store
into the PowerShell process, convert it to a `SecureString` if necessary, and
pass it to the script:

```powershell
# $clientSecretSecure is a nonempty SecureString obtained from your secret store.
.\scripts\WS2016_ESU_License_CSV.ps1 @parameters `
    -AuthenticationMode ServicePrincipal `
    -TenantId '<tenant-guid>' `
    -ClientId '<application-client-guid>' `
    -ClientSecret $clientSecretSecure `
    -Confirm:$false
```

`$clientSecretSecure` is deliberately not populated with a literal secret in
this example. Do not put secrets in the CSV, automation source, generated script
files, command-line arguments, or logs. Configure your automation platform to
redact secret-bearing inputs and output. Ensure `Az.Accounts` is installed for
the automation execution identity, and assign that service principal the required
resource-group RBAC permissions. Missing credentials and authentication errors
terminate execution; run the PowerShell host with `-NonInteractive` as an
additional safeguard.

**Azure Key Vault is another option for storing the service-principal secret.**
Retrieve it at runtime rather than embedding it in the script or configuration.
For example, on a host that supports managed identity, use that identity to read
the secret, then pass the returned `SecureString` to the service-principal
invocation above:

```powershell
# Requires the optional Az.KeyVault module and a configured managed identity.
Import-Module Az.KeyVault -ErrorAction Stop
Connect-AzAccount -Identity -Scope Process -ErrorAction Stop | Out-Null
$vaultSecret = Get-AzKeyVaultSecret `
    -VaultName '<key-vault-name>' `
    -Name '<service-principal-secret-name>' `
    -ErrorAction Stop
if (-not $vaultSecret -or -not $vaultSecret.SecretValue) {
    throw 'The service-principal secret could not be retrieved from Key Vault.'
}
$clientSecretSecure = $vaultSecret.SecretValue
```

The retrieving identity needs network access to the vault and permission to read
the secret, such as **Key Vault Secrets User** at the appropriate scope for a
vault using Azure RBAC, or **Get** secret permission for an access-policy vault.
This initial identity must authenticate independently; storing the secret in
Key Vault does not remove that requirement. The service principal used for ESU
assignment still needs its separate Arc RBAC permissions. Do not use
`-AsPlainText` or print the retrieved secret. If the managed identity already has
the required Arc permissions, you can instead use `ExistingContext` directly
without a service-principal secret.

See [Get-AzKeyVaultSecret](https://learn.microsoft.com/en-us/powershell/module/az.keyvault/get-azkeyvaultsecret)
and [Azure Key Vault RBAC guidance](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide).

The script's explicit sign-in modes use process-scoped Azure context and disable
context autosave for the process. Authentication and preflight reads still occur
with `-WhatIf`, but license assignments do not. For managed identity or
certificate-based automation, establish that session first and use
`ExistingContext`.

If the license is in another resource group, add
`-LicenseResourceGroupName 'rg-esu-licenses'`. The machine region is read
automatically. The CSV script is self-contained and does not require any
companion script or local module. The same agent, licensing, RBAC, and core-selection
cautions in this guide apply.

The script validates every CSV name before making any assignments and rejects
blank names, invalid names, and case-insensitive duplicates. It stops on the
first Azure failure, identifying the machine; earlier assignments remain in
place. Results are emitted as each machine completes. Re-running leaves
already-matching assignments unchanged. A different existing assignment requires
an explicit `-ReplaceExisting`.

Do not assume that increasing assignments increases licensed capacity. This is
**not transactional**: earlier successful rows remain linked if a later row fails.

## 5. Verify assignment, guest activation, and patching separately

### Azure assignment

```powershell
$profile = Invoke-AzRestMethod `
    -Path "${machineId}/licenseProfiles/default?api-version=2023-06-20-preview" `
    -Method GET -ErrorAction Stop
if ([int]$profile.StatusCode -ne 200) {
    throw "Profile read failed (HTTP $($profile.StatusCode)): $($profile.Content)"
}
($profile.Content | ConvertFrom-Json).properties.esuProfile | Format-List
```

Run this using an authenticated `Az.Accounts` session. The response includes
`assignedLicense`, `esuEligibility`, and `esuKeyState`. A 404 can mean no profile
exists; check the machine ID before interpreting it as an unassigned machine.
The CSV script also emits assignment, agent version, and Arc connection details.

`Linked` means **the ARM assignment was read back**, not that the guest is activated or patched. In particular, do not interpret `esuKeyState = Inactive` by itself as a failed Arc assignment; the original article discusses the volume-license key state, which is distinct from keyless Arc delivery.

For inventory, run this query in Azure Resource Graph Explorer:

```kusto
Resources
| where type =~ 'microsoft.hybridcompute/machines'
| where tostring(properties.osSku) contains 'Windows Server 2016'
    or tostring(properties.osName) contains 'Windows Server 2016'
| extend ArcStatus = tostring(properties.status),
         AgentVersion = tostring(properties.agentVersion),
         AssignedLicense = tostring(properties.licenseProfile.esuProfile.assignedLicense),
         AssignmentState = tostring(properties.licenseProfile.esuProfile.licenseAssignmentState),
         EsuEligibility = tostring(properties.licenseProfile.esuProfile.esuEligibility)
| project name, resourceGroup, subscriptionId, location,
          ArcStatus, AgentVersion, AssignmentState, AssignedLicense, EsuEligibility
```

Resource Graph is eventually consistent; projected fields can be empty until populated. Use the direct profile GET above for assignment read-back rather than treating an empty inventory field as authoritative.

### On the Windows Server 2016 guest

Microsoft's [2016 enrollment guide](https://learn.microsoft.com/en-us/azure/azure-arc/servers/deliver-extended-security-updates?pivots=windows-server-2016) specifies:

```powershell
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show
```

Confirm that the **Extended Security Updates** section shows **Active** after enrollment has propagated and the service is applicable. Before the ESU period begins, confirm the expected pre-enrollment behavior with current Microsoft guidance rather than claiming successful ESU patch delivery.

The 2012 article's registry value and `license.json` file checks are not used here as a definitive 2016 verification contract. Follow the documented 2016 agent check.

### Update installation

Use your normal update system to assess and install applicable updates, then confirm the expected KB/build and update compliance. An ESU assignment is an entitlement configuration, **not an update installation job**. As of this guide's date, Windows Server 2016 is still in extended support, so installing an ordinary current update does not validate future ESU delivery.

## 6. Unlink a machine

Use the Azure portal to unlink a machine, or follow the
[documented REST unlink request](https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates?pivots=windows-server-2016#unlink-a-license).
The CSV entry point assigns licenses only.

Unlink uses the documented PUT with an **empty ESU profile**, not an invented DELETE operation:

```json
{
  "location": "<region-read-from-the-Arc-machine>",
  "properties": {
    "esuProfile": {}
  }
}
```

Unlink is also allowed for upgraded or disconnected machines so stale assignments can be removed. It does not activate another license, uninstall previously installed updates, or delete/deactivate/resize the ESU license.

> **Billing warning:** Unlinking a server does not automatically reduce the provisioned cores or stop license billing. Billing is tied to activated licenses. Review remaining coverage before separately resizing or deactivating a license. See [license provisioning guidelines](https://learn.microsoft.com/en-us/azure/azure-arc/servers/license-extended-security-updates?pivots=windows-server-2016).

## Troubleshooting

| Symptom | Action |
| --- | --- |
| HTTP 401/403 | Check the selected tenant/subscription, identity, role scope, role propagation, and deny assignments. Do not assume onboarding access permits ESU management. |
| HTTP 404 reading a machine/license | Check full resource IDs and resource names. Only a missing machine license profile is an expected absence. |
| OS/version/connectivity preflight failure | Upgrade the agent, restore Arc connectivity, or wait for current inventory. Do not bypass these checks to force an assignment. |
| Deactivated/wrong-target license | Select an activated 2016 ESU license; do not activate or repurpose a 2012 license blindly. |
| Existing different assignment | Review it, then use `-ReplaceExisting` only if the replacement is intended. |
| Existing profile has other settings/tags | The CSV script updates only the ESU assignment using PATCH; unrelated fields are not sent or replaced. |
| Assignment accepted, guest not Active | Check timing, connectivity, certificate authorities, agent diagnostics, and enrollment in the portal. Do not equate assignment with activation. |
| Core type unclear or API validation error | Use the portal's explicit 2016 core selection and consult Microsoft about the API documentation gap before scaling automation. |
| Verification timeout | Read the profile again; the write may already have succeeded. Do not report the machine as verified until the expected ID is observed. |

See also [Troubleshoot delivery of Extended Security Updates](https://learn.microsoft.com/en-us/azure/azure-arc/servers/troubleshoot-extended-security-updates).

## Files

| File | Purpose |
| --- | --- |
| `scripts\WS2016_ESU_License.ps1` | Your original single-machine OAuth/REST script, unchanged. |
| `scripts\WS2016_ESU_License_CSV.ps1` | Self-contained CSV assignment script with interactive, service-principal, and existing-session authentication. |
| `examples\machine-names.csv` | Simple `MachineName` input for the CSV script. |

These examples require a live pilot in your subscription before production use
to confirm service availability, subscription eligibility, licensing compliance,
the undocumented core-selection behavior, and guest ESU activation.

## Sources

- [Microsoft Learn: Programmatically deploy and manage ESU licenses (2016)](https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates?pivots=windows-server-2016)
- [Microsoft Learn: Prepare delivery (2016)](https://learn.microsoft.com/en-us/azure/azure-arc/servers/prepare-extended-security-updates?pivots=windows-server-2016)
- [Microsoft Learn: Deliver ESUs and verify enrollment (2016)](https://learn.microsoft.com/en-us/azure/azure-arc/servers/deliver-extended-security-updates?pivots=windows-server-2016)
- [Microsoft Learn: License provisioning guidelines (2016)](https://learn.microsoft.com/en-us/azure/azure-arc/servers/license-extended-security-updates?pivots=windows-server-2016)
- [Microsoft Learn: License Profiles - Create Or Update, REST API 2026-09-01](https://learn.microsoft.com/en-us/rest/api/hybridcompute/license-profiles/create-or-update?view=rest-hybridcompute-2026-09-01)
- [Geek XING: Original Windows Server 2012 PowerShell/REST walkthrough](https://jpigott.com/2023/09/assigning-extended-service-updates-esu-to-an-azure-arc-enabled-windows-server-2012/)
