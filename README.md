# Azure Communication Services (ACS) SMTP PoC

PowerShell scripts for provisioning and testing Azure Communication Services SMTP with both legacy (username/password) and passwordless (OAuth2) authentication.

## Overview

This repository contains automation for setting up Azure Communication Services email delivery via SMTP, supporting two authentication methods:

- **Legacy Authentication**: Username/password (basic auth) - works with standard SMTP clients like `System.Net.Mail.SmtpClient`
- **Passwordless Authentication**: OAuth2 with managed identity or service principal - uses MailKit library for XOAUTH2 SASL support

## Prerequisites

### Azure PowerShell Version

**Minimum Required Version**: Az 12.4.0 (with Az.Communication preview module)

**Check your current version:**
```powershell
Get-InstalledModule -Name Az
```

**Install Az PowerShell (if not installed):**
```powershell
Install-Module -Name Az -Repository PSGallery -Scope CurrentUser -Force
```

**Update Az PowerShell (if version < 12.4.0):**
```powershell
Update-Module -Name Az -Scope CurrentUser -Force
```

### Required PowerShell Modules

```powershell
Install-Module -Name Az.Accounts -Scope CurrentUser
Install-Module -Name Az.Resources -Scope CurrentUser
Install-Module -Name Az.Communication -Scope CurrentUser
Install-Module -Name Az.KeyVault -Scope CurrentUser
Install-Module -Name Az.ManagedServiceIdentity -Scope CurrentUser
```

### Required NuGet Packages (for Passwordless)

```powershell
Install-Package -Name MailKit -ProviderName NuGet -Scope CurrentUser -Force
Install-Package -Name MimeKit -ProviderName NuGet -Scope CurrentUser -Force
```

### Azure Login

```powershell
Connect-AzAccount -UseDeviceAuthentication
```

## Architecture

The provisioning script creates the following Azure resources:

- **Azure Communication Service**: SMTP-enabled email service
- **Email Service**: Manages email domains and delivery
- **Email Domain**: Azure-managed domain (`*.azurecomm.net`) or custom domain
- **Key Vault**: Stores SMTP client secrets securely
- **Entra Applications** (2):
  - Legacy SMTP app with client secret (for basic auth)
  - Modern SMTP app with client secret (for OAuth2 local testing)
- **User-Assigned Managed Identity**: For passwordless authentication from Azure resources
- **SMTP Usernames**: Registered authentication credentials for both legacy and modern clients
- **Sender Addresses**: Registered MailFrom addresses

### Custom Domain Considerations

**By default**, the provisioning script creates an **Azure-managed domain** (`*.azurecomm.net`) which is ready to use immediately.

**For custom domains** (e.g., `@yourdomain.com`):
- Use the `-UseCustomerManagedDomain` and `-CustomDomainName` parameters
- **Additional DNS configuration is required** - you must manually add DNS TXT/CNAME records for domain verification
- The provisioning script will output the required DNS records, but you must add them to your DNS provider
- Email rate limits can be increased for verified custom domains
- See: [Add custom verified domains to Email Communication Service](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-custom-verified-domains?pivots=platform-azp)

## Quick Start

### 1. Provision Azure Resources

```powershell
cd scripts

./provision-acs-smtp.ps1 `
  -SubscriptionId "your-subscription-id" `
  -ResourceGroupName "rg-acs-smtp" `
  -Location "eastus" `
  -DataLocation "United States" `
  -CommunicationServiceName "acs-smtp-poc" `
  -EmailServiceName "acs-smtp-poc-email" `
  -LegacySmtpUsername "legacy-client" `
  -ModernSmtpUsername "modern-client" `
  -ManagedIdentityName "uami-acs-smtp" `
  -Verbose
```

The script outputs `provision-output.json` with all created resource details.

### 2. Send Email - Legacy (Username/Password)

```powershell
./send-email-smtp-legacy.ps1 `
    -SubscriptionId "your-subscription-id" `
    -KeyVaultName "kv-acs-smtp-poc" `
    -SecretName "smtp-legacy-client-secret" `
    -SmtpUsername "legacy-client@{domain}.azurecomm.net" `
    -Sender "noreply@{domain}.azurecomm.net" `
    -Recipient "user@example.com" `
    -Verbose
```

### 3. Send Email - Passwordless (OAuth2)

**Option A: Using Azure Login (Recommended for Local Testing)**

```powershell
./send-email-smtp-passwordless.ps1 `
    -SmtpUsername "modern-client@{domain}.azurecomm.net" `
    -Sender "modern-client@{domain}.azurecomm.net" `
    -Recipient "user@example.com" `
    -Verbose
```

**Option B: Using Service Principal (No Azure Login Required)**

```powershell
# Create SecureString from secret value
$secret = ConvertTo-SecureString "your-client-secret" -AsPlainText -Force

# Or retrieve from Key Vault and use .SecretValue
$secret = Get-AzKeyVaultSecret -VaultName "kv-acs-smtp-poc" -Name "smtp-modern-client-secret"

./send-email-smtp-passwordless.ps1 `
    -SmtpUsername "modern-client@{domain}.azurecomm.net" `
    -Sender "modern-client@{domain}.azurecomm.net" `
    -Recipient "user@example.com" `
    -AzureAdTenantId "your-tenant-id" `
    -AzureAdClientId "your-modern-client-app-id" `
    -AzureAdClientSecret $secret.SecretValue `
    -Verbose
```

**Option C: Using Managed Identity (On Azure Resources)**

```powershell
./send-email-smtp-passwordless.ps1 `
    -SmtpUsername "modern-client@{domain}.azurecomm.net" `
    -Sender "noreply@{domain}.azurecomm.net" `
    -Recipient "user@example.com" `
    -ManagedIdentityClientId "uami-client-id" `
    -Verbose
```

## Important Concepts

### SMTP Username vs Sender Address

- **SMTP Username**: Authentication credential (e.g., `legacy-client@domain.azurecomm.net`)
  - Used for SMTP authentication
  - Created via `New-AzCommunicationServiceSmtpUsername`
  - Visible in: Communication Service → Settings → SMTP credentials

- **Sender Address**: The "From" address in emails (e.g., `noreply@domain.azurecomm.net`)
  - Must be registered in Email Service Domain
  - Different from SMTP username
  - Visible in: Email Service → Provision domains → [Domain] → MailFrom addresses

### Token Scope for OAuth2

When using passwordless authentication, the token scope **must be**:
```
https://communication.azure.com/.default
```

❌ **NOT** `https://outlook.office365.com/.default` (common mistake)

## Scripts Reference

### `provision-acs-smtp.ps1`

Provisions all required Azure resources for ACS SMTP.

**Key Parameters:**
- `-SubscriptionId`: Azure subscription ID
- `-ResourceGroupName`: Resource group name (created if missing)
- `-Location`: Azure region (e.g., "eastus")
- `-DataLocation`: Data residency location (e.g., "United States")
- `-CommunicationServiceName`: Name for Communication Service
- `-EmailServiceName`: Name for Email Service
- `-LegacySmtpUsername`: Username for basic auth (default: "legacy-client")
- `-ModernSmtpUsername`: Username for OAuth2 auth (default: "modern-client")
- `-ManagedIdentityName`: User-assigned managed identity name
- `-KeyVaultName`: Optional - custom Key Vault name
- `-UseCustomerManagedDomain`: Switch for custom domain instead of Azure-managed
- `-CustomDomainName`: Custom domain name (requires DNS verification)

**Output:** Creates `provision-output.json` with all resource details

### `send-email-smtp-legacy.ps1`

Send email using username/password authentication.

**Key Parameters:**
- `-SmtpUsername`: SMTP authentication username
- `-Sender`: From address (must be registered)
- `-Recipient`: To address
- `-KeyVaultName` + `-SecretName`: Retrieve password from Key Vault
- `-Password`: Or provide SecureString password directly

**Note:** Uses `System.Net.Mail.SmtpClient` (standard .NET SMTP client)

### `send-email-smtp-passwordless.ps1`

Send email using OAuth2 authentication.

**Token Acquisition Methods (in order of preference):**
1. Managed Identity (IMDS) - when running on Azure
2. Current Azure login (Get-AzAccessToken) - local testing
3. Service Principal - explicit credentials
4. Direct token - pre-acquired access token

**Key Parameters:**
- `-SmtpUsername`: SMTP authentication username
- `-Sender`: From address (must be registered)
- `-Recipient`: To address
- `-ManagedIdentityClientId`: For managed identity auth
- `-AzureAdTenantId` + `-AzureAdClientId` + `-AzureAdClientSecret`: For service principal auth
- `-AccessToken`: For direct token auth

**Note:** Requires MailKit/MimeKit for OAuth2 XOAUTH2 SASL support

## Troubleshooting

### Email Not Received

1. **Check Azure Portal**: Email Service → Insights → Message Logs
2. **Check Spam/Junk Folder**: Emails often land in spam initially
3. **Delivery Time**: Can take several minutes

### "5.3.5 Email sender's username is invalid"

- SMTP username and sender address are different
- Ensure sender address is registered in Email Service Domain
- Use the provisioning script's `Ensure-SmtpSender` function to register senders

### "535: 5.7.3 Authentication unsuccessful" (Passwordless)

- Verify token scope is `https://communication.azure.com/.default`
- Check Entra application ID matches modern client app (not legacy app)
- Ensure client secret is valid and not expired

### "AADSTS7000215: Invalid client secret provided"

- When using Key Vault secret, use `$secret.SecretValue` not `$secret`
- When using `ConvertTo-SecureString`, use `$secret` directly

### MailKit Slow to Load

- Script optimized to check common NuGet package locations first
- Packages typically installed in: `C:\Users\{user}\AppData\Local\PackageManagement\NuGet\Packages\`

## References

- [ACS SMTP Authentication](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/send-email-smtp/smtp-authentication)
- [ACS Custom Domains](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-custom-verified-domains?pivots=platform-azp)
- [Email Rate Limits](https://learn.microsoft.com/en-us/azure/communication-services/concepts/service-limits#rate-limits-for-email)
- [Passwordless Overview](https://learn.microsoft.com/en-us/azure/developer/intro/passwordless-overview)
- [MailKit XOAUTH2](http://www.mimekit.net/docs/html/T_MailKit_Security_SaslMechanismOAuth2.htm)

## License

This project is licensed under the MIT License - see the [LICENSE.txt](LICENSE.txt) file for details.

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
