<#!
.SYNOPSIS
Provision an Azure Communication Services (ACS) resource with SMTP-ready email, legacy username/password credentials, and passwordless (managed identity) SMTP access.

.DESCRIPTION
Creates or updates the following assets in the target subscription:
1. Resource group (if missing).
2. Azure Communication Services resource with optional managed identity.
3. Email Communication Service resource in the requested data location.
4. Azure-managed (default) or customer-managed email domain and DNS verification scaffolding.
5. Key Vault for safely storing SMTP client secrets.
6. Microsoft Entra application/service principal bound to the ACS resource with the Communication and Email Service Owner role.
7. SMTP username for legacy PowerShell clients (password-based) plus fresh client secret stored in Key Vault.
8. User-assigned managed identity plus SMTP username for passwordless PowerShell clients that acquire OAuth tokens through Managed Identity.

The script outputs a structured summary and writes it to provision-output.json under the script folder for downstream automation.

.NOTES
- Requires Az 12.4.0+ with the Az.Communication module (preview as of 2025-02).
- Ensure you are logged in using something similar to: Connect-AzAccount -Subscription $SubscriptionId -UseDeviceAuthentication
- For custom domains, DNS TXT/CNAME records must be added manually; the script prints the required values.
- Passwordless clients must run on Azure compute that supports user-assigned managed identities (for example, Automation Account, Function App, Arc-enabled server, VM, Container Apps, etc.).
- References:
  * ACS SMTP using custom domains: https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-custom-verified-domains?pivots=platform-azp
  * Email Rate limits (all can be increased for custom domains): https://learn.microsoft.com/en-us/azure/communication-services/concepts/service-limits#rate-limits-for-email
  * SMTP onboarding and credential guidance: https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/send-email-smtp/smtp-authentication
  * Email domain automation: https://learn.microsoft.com/en-us/azure/communication-services/samples/email-resource-management?pivots=platform-powershell
  * SMTP username cmdlet: https://learn.microsoft.com/en-us/powershell/module/az.communication/new-azcommunicationservicesmtpusername
  * Passwordless managed identity overview: https://learn.microsoft.com/en-us/azure/developer/intro/passwordless-overview

.EXAMPLE
./provision-acs-smtp.ps1 `
  -SubscriptionId "00000000-0000-0000-0000-000000000000" `
  -ResourceGroupName "rg-acs-smtp" `
  -Location "eastus" `
  -DataLocation "United States" `
  -CommunicationServiceName "acs-smtp-poc" `
  -EmailServiceName "acs-smtp-poc-email" `
  -LegacySmtpUsername "legacy-client" `
  -ModernSmtpUsername "modern-client" `
  -ManagedIdentityName "uami-acs-smtp"

#>



[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$DataLocation,

    [Parameter(Mandatory = $true)]
    [string]$CommunicationServiceName,

    [Parameter(Mandatory = $true)]
    [string]$EmailServiceName,

    [string]$LegacySmtpUsername = "legacy-client",

    [string]$ModernSmtpUsername = "modern-client",

    [string]$ManagedIdentityName = "uami-acs-smtp",

    [string]$KeyVaultName,

    [switch]$UseCustomerManagedDomain,

    [string]$CustomDomainName,

    [switch]$SkipDomainVerification,

    [datetime]$ClientSecretExpiry = (Get-Date).AddYears(1)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredModules = @(
    'Az.Accounts',
    'Az.Resources',
    'Az.Communication',
    'Az.KeyVault',
    'Az.ManagedServiceIdentity'
)
foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        throw "Required module '$moduleName' is missing. Install it with Install-Module $moduleName -Scope CurrentUser before running this script."
    }
}

function Ensure-SubscriptionContext {
    param([string]$Id)
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Connect-AzAccount -Subscription $Id | Out-Null
    }
    Select-AzSubscription -SubscriptionId $Id | Out-Null
    return (Get-AzContext)
}

function Ensure-ResourceGroup {
    param(
        [string]$Name,
        [string]$Region
    )
    $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Verbose "Creating resource group $Name in $Region."
        $rg = New-AzResourceGroup -Name $Name -Location $Region
    }
    return $rg
}

function Ensure-KeyVault {
    param(
        [string]$Name,
        [string]$ResourceGroup,
        [string]$Region
    )
    $vault = Get-AzKeyVault -VaultName $Name -ErrorAction SilentlyContinue
    if (-not $vault) {
        Write-Verbose "Creating Key Vault $Name."
        $vault = New-AzKeyVault -Name $Name -ResourceGroupName $ResourceGroup -Location $Region -EnablePurgeProtection -Sku Standard
    }
    return $vault
}

function Get-CurrentPrincipalObjectId {
    param($Context)
    if (-not $Context -or -not $Context.Account) {
        return $null
    }

    $accountId = $Context.Account.Id
    $accountType = $Context.Account.Type
    if ([string]::IsNullOrWhiteSpace($accountId)) {
        return $null
    }

    if ($accountType -eq 'User') {
        $user = Get-AzADUser -UserPrincipalName $accountId -ErrorAction SilentlyContinue
        if (-not $user) {
            $guid = [Guid]::Empty
            if ([Guid]::TryParse($accountId, [ref]$guid)) {
                $user = Get-AzADUser -ObjectId $accountId -ErrorAction SilentlyContinue
            }
        }
        return $user.Id
    }

    $sp = Get-AzADServicePrincipal -ApplicationId $accountId -ErrorAction SilentlyContinue
    if (-not $sp) {
        $guid = [Guid]::Empty
        if ([Guid]::TryParse($accountId, [ref]$guid)) {
            $sp = Get-AzADServicePrincipal -ObjectId $accountId -ErrorAction SilentlyContinue
        }
    }
    return $sp?.Id
}

function Ensure-KeyVaultSecretPermissions {
    param(
        $Vault,
        [string]$CallerObjectId
    )
    if (-not $Vault -or [string]::IsNullOrWhiteSpace($CallerObjectId)) {
        return $Vault
    }

    if ($Vault.EnableRbacAuthorization) {
        Write-Verbose "Key Vault $($Vault.VaultName) uses RBAC; assigning Key Vault Secrets Officer to the caller."
        Ensure-RoleAssignment -RoleDefinitionName 'Key Vault Secrets Officer' -Scope $Vault.ResourceId -ObjectId $CallerObjectId | Out-Null
        return $Vault
    }
    else {
        $policy = $Vault.AccessPolicies | Where-Object { $_.ObjectId -eq $CallerObjectId }
        $required = @('Get', 'Set', 'List')
        $missing = if ($policy) { $required | Where-Object { $_ -notin $policy.PermissionsToSecrets } } else { $required }

        if (-not $missing -or $missing.Count -eq 0) {
            return $Vault
        }

        Write-Verbose "Granting caller secret permissions on Key Vault $($Vault.VaultName)."
        return Set-AzKeyVaultAccessPolicy -VaultName $Vault.VaultName -ObjectId $CallerObjectId -PermissionsToSecrets Get,Set,List -PassThru
    }
}

function Ensure-CommunicationService {
    param(
        [string]$Name,
        [string]$ResourceGroup,
        [string]$DataRegion
    )
    $service = Get-AzCommunicationService -Name $Name -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Verbose "Creating Communication Service $Name."
        $service = New-AzCommunicationService -Name $Name -ResourceGroupName $ResourceGroup -Location 'Global' -DataLocation $DataRegion -EnableSystemAssignedIdentity
    }
    return $service
}

function Ensure-EmailService {
    param(
        [string]$Name,
        [string]$ResourceGroup,
        [string]$DataRegion
    )
    $emailService = Get-AzEmailService -Name $Name -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $emailService) {
        Write-Verbose "Creating Email Service $Name."
        $emailService = New-AzEmailService -Name $Name -ResourceGroupName $ResourceGroup -DataLocation $DataRegion -Location 'Global'
    }
    return $emailService
}

function Ensure-EmailDomain {
    param(
        [string]$DomainName,
        [string]$EmailServiceName,
        [string]$ResourceGroup,
        [string]$DomainManagement
    )
    $domain = Get-AzEmailServiceDomain -Name $DomainName -EmailServiceName $EmailServiceName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $domain) {
        Write-Verbose "Creating $DomainManagement email domain $DomainName."
        $domain = New-AzEmailServiceDomain -Name $DomainName -EmailServiceName $EmailServiceName -ResourceGroupName $ResourceGroup -DomainManagement $DomainManagement -Location 'Global'
    }
    return $domain
}

function Link-DomainToCommunicationService {
    param(
        [Microsoft.Azure.PowerShell.Cmdlets.Communication.Models.ICommunicationServiceResource]$Service,
        [string]$DomainId,
        [string]$ResourceGroup
    )
    if ($Service.LinkedDomain -and $Service.LinkedDomain -contains $DomainId) {
        return $Service
    }
    Write-Verbose "Linking domain $DomainId to ACS $($Service.Name)."
    return Update-AzCommunicationService -Name $Service.Name -ResourceGroupName $ResourceGroup -LinkedDomain @($DomainId)
}

function Ensure-AadApplication {
    param([string]$DisplayName)
    $app = Get-AzADApplication -DisplayName $DisplayName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $app) {
        Write-Verbose "Creating Microsoft Entra application $DisplayName."
        $app = New-AzADApplication -DisplayName $DisplayName -SignInAudience AzureADMyOrg
    }
    $sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
    if (-not $sp) {
        Write-Verbose "Creating service principal for $DisplayName."
        $sp = New-AzADServicePrincipal -AppId $app.AppId
    }
    return [PSCustomObject]@{
        Application      = $app
        ServicePrincipal = $sp
    }
}

function Ensure-RoleAssignment {
    param(
        [string]$RoleDefinitionName,
        [string]$Scope,
        [string]$ObjectId
    )
    $assignment = Get-AzRoleAssignment -Scope $Scope -ObjectId $ObjectId -ErrorAction SilentlyContinue | Where-Object { $_.RoleDefinitionName -eq $RoleDefinitionName }
    if (-not $assignment) {
        Write-Verbose "Assigning role $RoleDefinitionName on $Scope."
        New-AzRoleAssignment -Scope $Scope -RoleDefinitionName $RoleDefinitionName -ObjectId $ObjectId | Out-Null
    }
}

function New-LegacyClientSecret {
    param(
        [Microsoft.Azure.PowerShell.Cmdlets.Resources.MSGraph.Models.ApiV10.IMicrosoftGraphApplication]$Application,
        [string]$VaultName,
        [datetime]$Expiry,
        [string]$SecretName
    )
    Write-Verbose "Creating new client secret for Entra application $($Application.DisplayName)."
    $credential = New-AzADAppCredential -ObjectId $Application.Id -EndDate $Expiry
    if ($credential.SecretText -is [SecureString]) {
        Write-Verbose "Secret is already a SecureString."
        $Password = $credential.SecretText
    }
    elseif ($credential.SecretText) {
        Write-Verbose "Converting secret to SecureString."
        $Password = ConvertTo-SecureString -String $credential.SecretText -AsPlainText -Force
    }
    else {
        throw "Secret '$SecretName' did not contain a retrievable value."
    }

    Write-Verbose "Writing client secret of $($credential.SecretText.Substring(0,3))****************** to Key Vault $VaultName / $SecretName."
    Set-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $Password | Out-Null
    return "$($credential.SecretText.Substring(0,3))******************"
}

function Ensure-UserAssignedIdentity {
    param(
        [string]$Name,
        [string]$ResourceGroup,
        [string]$Region
    )
    $identity = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if (-not $identity) {
        Write-Verbose "Creating user-assigned managed identity $Name."
        $identity = New-AzUserAssignedIdentity -ResourceGroupName $ResourceGroup -Name $Name -Location $Region
    }
    return $identity
}

function Ensure-SmtpUsername {
    param(
        [string]$ResourceName,
        [string]$CommunicationServiceName,
        [string]$ResourceGroupName,
        [string]$DisplayUsername,
        [string]$ApplicationId,
        [string]$TenantId
    )
    $existing = Get-AzCommunicationServiceSmtpUsername -CommunicationServiceName $CommunicationServiceName -ResourceGroupName $ResourceGroupName -SmtpUsername $ResourceName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.EntraApplicationId -ne $ApplicationId -or $existing.Username -ne $DisplayUsername) {
            Write-Verbose "Updating SMTP username $ResourceName."
            return Update-AzCommunicationServiceSmtpUsername -CommunicationServiceName $CommunicationServiceName -ResourceGroupName $ResourceGroupName -SmtpUsername $ResourceName -EntraApplicationId $ApplicationId -TenantId $TenantId -Username $DisplayUsername
        }
        return $existing
    }
    Write-Verbose "Creating SMTP username $ResourceName for $DisplayUsername."
    return New-AzCommunicationServiceSmtpUsername -CommunicationServiceName $CommunicationServiceName -ResourceGroupName $ResourceGroupName -SmtpUsername $ResourceName -EntraApplicationId $ApplicationId -TenantId $TenantId -Username $DisplayUsername
}

function Get-CanonicalSmtpLogin {
    param(
        [Microsoft.Azure.PowerShell.Cmdlets.EmailService.Models.IDomainResource]$Domain,
        [string]$LocalPart
    )
    if ($Domain.FromSenderDomain) {
        return "$LocalPart@$($Domain.FromSenderDomain)"
    }
    return "$LocalPart@$($Domain.Name)"
}

function Ensure-SmtpSender {
    param(
        [string]$Username,
        [string]$DisplayName,
        [string]$EmailServiceName,
        [string]$DomainName,
        [string]$ResourceGroupName
    )
    $existing = Get-AzEmailServiceSenderUsername -EmailServiceName $EmailServiceName -DomainName $DomainName -ResourceGroupName $ResourceGroupName -SenderUsername $Username -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Sender username $Username already exists."
        return $existing
    }
    Write-Verbose "Creating sender username $Username with display name $DisplayName."
    return New-AzEmailServiceSenderUsername -EmailServiceName $EmailServiceName -DomainName $DomainName -ResourceGroupName $ResourceGroupName -SenderUsername $Username -Username $DisplayName -DisplayName $DisplayName
}


###############################################################################################
####                                Main Code Starts Here                                  ####
###############################################################################################


if ($UseCustomerManagedDomain -and [string]::IsNullOrWhiteSpace($CustomDomainName)) {
    throw "CustomDomainName is required when -UseCustomerManagedDomain is specified."
}

if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
    $sanitized = ($CommunicationServiceName.ToLowerInvariant() -replace '[^a-z0-9-]', '')
    $candidate = "kv-$sanitized"
    $candidate = $candidate.Substring(0, [Math]::Min(24, $candidate.Length))
    if ($candidate.Length -lt 3) {
        $candidate = "kv$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
    }
    $KeyVaultName = $candidate
}

$context = Ensure-SubscriptionContext -Id $SubscriptionId
$tenantId = $context.Tenant.Id

$resourceGroup = Ensure-ResourceGroup -Name $ResourceGroupName -Region $Location
$keyVault = Ensure-KeyVault -Name $KeyVaultName -ResourceGroup $ResourceGroupName -Region $Location
$callerObjectId = Get-CurrentPrincipalObjectId -Context $context
if ($callerObjectId) {
    $keyVault = Ensure-KeyVaultSecretPermissions -Vault $keyVault -CallerObjectId $callerObjectId
} else {
    Write-Warning "Unable to resolve the caller's object ID; ensure your principal has secret permissions on Key Vault $($keyVault.VaultName)."
}
$communicationService = Ensure-CommunicationService -Name $CommunicationServiceName -ResourceGroup $ResourceGroupName -DataRegion $DataLocation
$emailService = Ensure-EmailService -Name $EmailServiceName -ResourceGroup $ResourceGroupName -DataRegion $DataLocation

$domainName = $UseCustomerManagedDomain ? $CustomDomainName : 'AzureManagedDomain'
$domainManagementMode = $UseCustomerManagedDomain ? 'CustomerManaged' : 'AzureManaged'
$emailDomain = Ensure-EmailDomain -DomainName $domainName -EmailServiceName $EmailServiceName -ResourceGroup $ResourceGroupName -DomainManagement $domainManagementMode
$communicationService = Link-DomainToCommunicationService -Service $communicationService -DomainId $emailDomain.Id -ResourceGroup $ResourceGroupName

$secretName = "smtp-$($LegacySmtpUsername)-secret"
$entraAppName = "$($CommunicationServiceName)-smtp-app"
$legacyAad = Ensure-AadApplication -DisplayName $entraAppName
Ensure-RoleAssignment -RoleDefinitionName 'Communication and Email Service Owner' -Scope $communicationService.Id -ObjectId $legacyAad.ServicePrincipal.Id

$legacyLogin = Get-CanonicalSmtpLogin -Domain $emailDomain -LocalPart $LegacySmtpUsername
$legacySecret = New-LegacyClientSecret -Application $legacyAad.Application -VaultName $keyVault.VaultName -Expiry $ClientSecretExpiry -SecretName $secretName
$legacySmtpResource = Ensure-SmtpUsername -ResourceName "smtp-$($LegacySmtpUsername)" -CommunicationServiceName $CommunicationServiceName -ResourceGroup $ResourceGroupName -DisplayUsername $legacyLogin -ApplicationId $legacyAad.Application.AppId -TenantId $tenantId
$legacySender = Ensure-SmtpSender -Username $LegacySmtpUsername -DisplayName $LegacySmtpUsername -EmailServiceName $EmailServiceName -DomainName $domainName -ResourceGroupName $ResourceGroupName

# Create Entra application for modern/passwordless client (for local testing with service principal)
$modernEntraAppName = "$($CommunicationServiceName)-modern-smtp-app"
$modernAad = Ensure-AadApplication -DisplayName $modernEntraAppName
Ensure-RoleAssignment -RoleDefinitionName 'Communication and Email Service Owner' -Scope $communicationService.Id -ObjectId $modernAad.ServicePrincipal.Id

$modernSecretName = "smtp-$($ModernSmtpUsername)-secret"
$modernSecret = New-LegacyClientSecret -Application $modernAad.Application -VaultName $keyVault.VaultName -Expiry $ClientSecretExpiry -SecretName $modernSecretName

# Also create managed identity for true passwordless scenarios on Azure resources
$managedIdentity = Ensure-UserAssignedIdentity -Name $ManagedIdentityName -ResourceGroup $ResourceGroupName -Region $Location
Ensure-RoleAssignment -RoleDefinitionName 'Communication and Email Service Owner' -Scope $communicationService.Id -ObjectId $managedIdentity.PrincipalId

$modernLogin = Get-CanonicalSmtpLogin -Domain $emailDomain -LocalPart $ModernSmtpUsername
$modernSmtpResource = Ensure-SmtpUsername -ResourceName "smtp-$($ModernSmtpUsername)" -CommunicationServiceName $CommunicationServiceName -ResourceGroup $ResourceGroupName -DisplayUsername $modernLogin -ApplicationId $modernAad.Application.AppId -TenantId $tenantId
$modernSender = Ensure-SmtpSender -Username $ModernSmtpUsername -DisplayName $ModernSmtpUsername -EmailServiceName $EmailServiceName -DomainName $domainName -ResourceGroupName $ResourceGroupName

if ($UseCustomerManagedDomain -and -not $SkipDomainVerification) {
    Write-Host "Custom domain DNS verification records:" -ForegroundColor Cyan
    ($emailDomain.VerificationRecord.GetEnumerator() | Sort-Object Name) | ForEach-Object {
        $record = $_.Value
        Write-Host ("Type: {0}, Host: {1}, Value: {2}" -f $record.type, $record.name, $record.value)
    }
    Write-Host "Run Invoke-AzEmailServiceInitiateDomainVerification for Domain, SPF, DKIM, and DKIM2 after publishing DNS records." -ForegroundColor Yellow
}

$summary = [PSCustomObject]@{
    SubscriptionId              = $SubscriptionId
    ResourceGroup               = $ResourceGroupName
    CommunicationServiceId      = $communicationService.Id
    EmailServiceId              = $emailService.Id
    Domain                      = [PSCustomObject]@{
        Name                  = $emailDomain.Name
        ManagementMode        = $emailDomain.DomainManagement
        MailFrom              = $emailDomain.MailFromSenderDomain
        FromAddressDomain     = $emailDomain.FromSenderDomain
        VerificationRecords   = $emailDomain.VerificationRecord
    }
    LegacySmtpCredential        = [PSCustomObject]@{
        UsernameResourceId    = $legacySmtpResource.Id
        Username              = $legacySmtpResource.Username
        SenderUsername        = $legacySender.Username
        SenderDisplayName     = $legacySender.DisplayName
        SecretKeyVaultUri     = $keyVault.VaultUri
        SecretName            = $secretName
        SecretExpiry          = $ClientSecretExpiry
        AadApplicationId      = $legacyAad.Application.AppId
        AadDisplayName        = $legacyAad.Application.DisplayName
        AadSecret             = $legacySecret
    }
    ModernSmtpCredential        = [PSCustomObject]@{
        UsernameResourceId    = $modernSmtpResource.Id
        Username              = $modernSmtpResource.Username
        SenderUsername        = $modernSender.Username
        SenderDisplayName     = $modernSender.DisplayName
        SecretKeyVaultUri     = $keyVault.VaultUri
        SecretName            = $modernSecretName
        SecretExpiry          = $ClientSecretExpiry
        AadApplicationId      = $modernAad.Application.AppId
        AadDisplayName        = $modernAad.Application.DisplayName
        AadSecret             = $modernSecret
    }
    ManagedIdentity             = [PSCustomObject]@{
        UserAssignedIdentityId  = $managedIdentity.Id
        ManagedIdentityClientId = $managedIdentity.ClientId
    }
    SmtpEndpoint                = 'smtp.azurecomm.net'
}

$summaryPath = Join-Path -Path $PSScriptRoot -ChildPath 'provision-output.json'
$summary | ConvertTo-Json -Depth 10 | Out-File -FilePath $summaryPath -Encoding UTF8

Write-Host "Provisioning complete." -ForegroundColor Green
Write-Host "Summary written to $summaryPath" -ForegroundColor Green
Write-Host ""
Write-Host "Legacy SMTP (username/password):" -ForegroundColor Cyan
Write-Host "  Secret: $($summary.LegacySmtpCredential.SecretName) in Key Vault $KeyVaultName" -ForegroundColor Cyan
Write-Host ""
Write-Host "Modern SMTP (OAuth2 - local testing):" -ForegroundColor Cyan
Write-Host "  Secret: $($summary.ModernSmtpCredential.SecretName) in Key Vault $KeyVaultName" -ForegroundColor Cyan
Write-Host "  App ID: $($summary.ModernSmtpCredential.AadApplicationId)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Managed Identity (OAuth2 - Azure resources):" -ForegroundColor Cyan
Write-Host "  Identity: $ManagedIdentityName" -ForegroundColor Cyan
Write-Host "  Assign this identity to your Azure resources for true passwordless SMTP." -ForegroundColor Cyan