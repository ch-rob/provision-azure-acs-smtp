<#!
.SYNOPSIS
Send a basic test email through Azure Communication Services (ACS) SMTP using passwordless authentication (managed identity + OAuth 2.0 XOAUTH2).

.DESCRIPTION
Acquires an access token for https://outlook.office365.com/ and performs SMTP authentication using OAuth 2.0. 

Token acquisition methods (in order of preference):
1. Managed Identity (IMDS) - when running on Azure resources with assigned managed identity
2. Current Azure login (Get-AzAccessToken) - when running locally with an active Azure session
3. Service Principal - when explicit credentials are provided
4. Direct token - when an access token is provided directly

The script uses MailKit/MimeKit for SMTP OAuth2 support. Reference: https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/send-email-smtp/send-email-smtp-oauth

.EXAMPLE
!!! Must run once - ensure mailkit is installed:
    Install-Package -Name 'MimeKit' -Source "https://www.nuget.org/api/v2" -SkipDependencies -Scope CurrentUser
    Install-Package -Name 'MailKit' -Source "https://www.nuget.org/api/v2" -SkipDependencies -Scope CurrentUser

# Running locally (uses your current Azure login (Connect-AzAccount -UseDeviceAuthentication) )
./send-email-smtp-passwordless.ps1 `
    -SmtpUsername "modern-client@xyz.azurecomm.net" `
    -Sender "modern-client@xyz.azurecomm.net" `
    -Recipient "user@contoso.com" `
    -Verbose

# Running on Azure with managed identity
./send-email-smtp-passwordless.ps1 `
    -SmtpUsername "modern-client@contoso.azurecomm.net" `
    -Sender "no-reply@contoso.azurecomm.net" `
    -Recipient "user@contoso.com" `
    -ManagedIdentityClientId "11111111-2222-3333-4444-555555555555"

# Without login
# To pass in secret...
#   Interactively...
#       $secret = Read-Host "Enter Azure AD Client Secret" -AsSecureString
#   Or set a variable...
#       $secret = (ConvertTo-SecureString "YourSecretValue" -AsPlainText -Force)
#   Or from Key Vault:
#       $secret = (Get-AzKeyVaultSecret -VaultName "kv-acs-smtp-poc" -Name "smtp-modern-client-secret").SecretValue

# To see the plain text string...
#       $secret |  ConvertFrom-SecureString -AsPlainText
 
./send-email-smtp-passwordless.ps1 `
    -SmtpUsername "modern-client@xyz.azurecomm.net" `
    -Sender "modern-client@xyz.azurecomm.net" `
    -Recipient "user@contoso.com" `
    -AzureAdTenantId "11111111-2222-3333-4444-555555555555" `
    -AzureAdClientId "11111111-2222-3333-4444-555555555555" `
    -AzureAdClientSecret $secret `
    -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SmtpUsername,

    [Parameter(Mandatory = $true)]
    [string]$Sender,

    [Parameter(Mandatory = $true)]
    [string]$Recipient,

    [string]$Subject = 'ACS SMTP Passwordless Test',

    [string]$Body = 'Hello from Azure Communication Services SMTP using managed identity.',

    [string]$SmtpHost = 'smtp.azurecomm.net',

    [int]$Port = 587,

    [string]$ManagedIdentityClientId,

    [string]$AzureAdTenantId,

    [string]$AzureAdClientId,

    [SecureString]$AzureAdClientSecret,

    [string]$AccessToken,

    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-MailKitAssemblies {
    # Check if already loaded
    if ([Type]::GetType('MailKit.Net.Smtp.SmtpClient, MailKit', $false)) {
        Write-Verbose "MailKit already loaded."
        return
    }

    Write-Verbose "Loading MailKit/MimeKit assemblies..."
    
    # Try common installation paths first (much faster than recursive search)
    $nugetPackagesRoot = Join-Path $env:USERPROFILE '.nuget/packages'
    $pmPackagesRoot = Join-Path $env:LOCALAPPDATA 'PackageManagement\NuGet\Packages'
    
    $commonPaths = @(
        # PackageManagement location (Install-Package)
        @{
            MailKit = "$pmPackagesRoot\MailKit.4.14.1\lib\net462\MailKit.dll"
            MimeKit = "$pmPackagesRoot\MimeKit.4.14.0\lib\net462\MimeKit.dll"
        },
        @{
            MailKit = "$pmPackagesRoot\MailKit.4.14.0\lib\net462\MailKit.dll"
            MimeKit = "$pmPackagesRoot\MimeKit.4.14.0\lib\net462\MimeKit.dll"
        },
        # Standard NuGet location
        @{
            MailKit = "$nugetPackagesRoot\mailkit\4.14.1\lib\net8.0\MailKit.dll"
            MimeKit = "$nugetPackagesRoot\mimekit\4.14.0\lib\net8.0\MimeKit.dll"
        },
        @{
            MailKit = "$nugetPackagesRoot\mailkit\4.9.0\lib\net8.0\MailKit.dll"
            MimeKit = "$nugetPackagesRoot\mimekit\4.9.0\lib\net8.0\MimeKit.dll"
        },
        @{
            MailKit = "$nugetPackagesRoot\mailkit\4.8.0\lib\net6.0\MailKit.dll"
            MimeKit = "$nugetPackagesRoot\mimekit\4.8.0\lib\net6.0\MimeKit.dll"
        }
    )
    
    $mailKitPath = $null
    $mimeKitPath = $null
    
    foreach ($paths in $commonPaths) {
        if ((Test-Path $paths.MailKit) -and (Test-Path $paths.MimeKit)) {
            $mailKitPath = Get-Item $paths.MailKit
            $mimeKitPath = Get-Item $paths.MimeKit
            Write-Verbose "Found MailKit at: $($mailKitPath.FullName)"
            break
        }
    }
    
    # Fall back to search if not found in common paths
    if (-not $mailKitPath) {
        Write-Verbose "Searching for MailKit in package locations..."
        
        # Search PackageManagement location first
        if (Test-Path $pmPackagesRoot) {
            $mailKitPath = Get-ChildItem -Path $pmPackagesRoot -Filter 'MailKit.dll' -Recurse -ErrorAction SilentlyContinue | 
                Where-Object { $_.FullName -like '*\lib\*' } | 
                Sort-Object FullName -Descending | 
                Select-Object -First 1
            $mimeKitPath = Get-ChildItem -Path $pmPackagesRoot -Filter 'MimeKit.dll' -Recurse -ErrorAction SilentlyContinue | 
                Where-Object { $_.FullName -like '*\lib\*' } | 
                Sort-Object FullName -Descending | 
                Select-Object -First 1
        }
        
        # Search standard NuGet location
        if (-not $mailKitPath -and (Test-Path $nugetPackagesRoot)) {
            $mailKitPath = Get-ChildItem -Path "$nugetPackagesRoot\mailkit" -Filter 'MailKit.dll' -Recurse -ErrorAction SilentlyContinue | 
                Where-Object { $_.FullName -like '*\lib\net*.0\*' } | 
                Sort-Object FullName -Descending | 
                Select-Object -First 1
            $mimeKitPath = Get-ChildItem -Path "$nugetPackagesRoot\mimekit" -Filter 'MimeKit.dll' -Recurse -ErrorAction SilentlyContinue | 
                Where-Object { $_.FullName -like '*\lib\net*.0\*' } | 
                Sort-Object FullName -Descending | 
                Select-Object -First 1
        }
    }

    # Install if not found
    if (-not ($mailKitPath -and $mimeKitPath)) {
        Write-Host 'MailKit/MimeKit not found. Installing... (this is a one-time operation)' -ForegroundColor Yellow
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -WarningAction SilentlyContinue | Out-Null
        }
        Install-Package -Name MailKit -ProviderName NuGet -Scope CurrentUser -Force -SkipDependencies -WarningAction SilentlyContinue | Out-Null
        Install-Package -Name MimeKit -ProviderName NuGet -Scope CurrentUser -Force -SkipDependencies -WarningAction SilentlyContinue | Out-Null
        
        # Try common paths again
        foreach ($paths in $commonPaths) {
            if ((Test-Path $paths.MailKit) -and (Test-Path $paths.MimeKit)) {
                $mailKitPath = Get-Item $paths.MailKit
                $mimeKitPath = Get-Item $paths.MimeKit
                break
            }
        }
    }

    if (-not ($mailKitPath -and $mimeKitPath)) {
        throw 'Unable to locate MailKit/MimeKit assemblies. Please install manually: Install-Package MailKit -Scope CurrentUser'
    }

    Write-Verbose "Loading: $($mimeKitPath.FullName)"
    Add-Type -Path $mimeKitPath.FullName
    Write-Verbose "Loading: $($mailKitPath.FullName)"
    Add-Type -Path $mailKitPath.FullName
    Write-Verbose "MailKit loaded successfully."
}

function Get-ManagedIdentityToken {
    param([string]$ClientId)
    Write-Verbose "Acquiring managed identity token from IMDS..."
    try {
        # Note: ACS SMTP requires token for https://communication.azure.com scope
        $resource = [uri]::EscapeDataString('https://communication.azure.com/')
        $baseUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=$resource"
        if ($ClientId) {
            $baseUri += "&client_id=$ClientId"
        }
        $headers = @{ Metadata = 'true' }
        $response = Invoke-RestMethod -Method Get -Uri $baseUri -Headers $headers -TimeoutSec 5
        return $response.access_token
    }
    catch {
        Write-Verbose "IMDS not accessible (not running on Azure): $($_.Exception.Message)"
        Write-Verbose "Falling back to current Azure login context..."
        
        Import-Module Az.Accounts -ErrorAction Stop
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context) {
            throw "No Azure context found. Run Connect-AzAccount first or provide service principal credentials."
        }
        
        Write-Verbose "Using Azure account: $($context.Account.Id)"
        # Note: ACS SMTP requires token for https://communication.azure.com scope
        $token = (Get-AzAccessToken -ResourceUrl "https://communication.azure.com").Token
        if (-not $token) {
            throw "Failed to acquire token using current Azure context."
        }
        return $token
    }
}

function Get-ServicePrincipalToken {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][SecureString]$ClientSecret
    )
    $plainSecretPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    try {
        $plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($plainSecretPtr)
        Write-Verbose "Acquiring service principal token from Azure AD using client ID $ClientId and secret $($plainSecret.Substring(0,3))****************** ..."
        # Note: ACS SMTP requires token for https://communication.azure.com scope
        $body = "client_id=$ClientId&scope=https%3A%2F%2Fcommunication.azure.com%2F.default&client_secret=$([uri]::EscapeDataString($plainSecret))&grant_type=client_credentials"
        $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec $TimeoutSeconds

        # For futher debuging set to $true...
        if($false){
            Write-Verbose "Access token acquired successfully: $($response.access_token)"
        } else {
            Write-Verbose "Access token acquired successfully: $($response.access_token.Substring(0,20))******************"
        }

        return $response.access_token
    }
    finally {
        if ($plainSecretPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($plainSecretPtr)
        }
    }
}

# Token acquisition strategy - tries methods in order of precedence
if ($AccessToken) {
    # Scenario 1: Pre-acquired token provided directly
    # Use case: You've already obtained a token from another process/tool and want to reuse it
    # Example: Token from 'az account get-access-token --resource https://outlook.office365.com'

    Write-Verbose "Using provided access token."
    $token = $AccessToken
}
elseif ($AzureAdTenantId -and $AzureAdClientId -and $AzureAdClientSecret) {
    # Scenario 2: Service principal authentication (best for local development/testing)
    # Use case: Running locally on your workstation, in CI/CD pipelines, or any non-Azure environment
    # Requires: Entra app registration with client secret stored in Key Vault
    # Example: ./send-email-smtp-passwordless.ps1 -AzureAdTenantId "..." -AzureAdClientId "..." -AzureAdClientSecret $secret

    Write-Verbose "Acquiring token using service principal (local/CI-CD scenario)..."
    $token = Get-ServicePrincipalToken -TenantId $AzureAdTenantId -ClientId $AzureAdClientId -ClientSecret $AzureAdClientSecret
}
else {
    # Scenario 3: Managed identity or current Azure login (true passwordless)
    # Use case: Running on Azure resources (VM, Function App, Container Apps, etc.) with assigned managed identity
    #           OR running locally with an active Azure CLI/PowerShell login session
    # Requires: For Azure resources - user-assigned or system-assigned managed identity
    #           For local - active Azure session (Connect-AzAccount)
    # Example: ./send-email-smtp-passwordless.ps1 -ManagedIdentityClientId "..." (on Azure VM)
    #          ./send-email-smtp-passwordless.ps1 (locally with Azure login)

    Write-Verbose "Attempting to acquire token using managed identity or current Azure login..."
    $token = Get-ManagedIdentityToken -ClientId $ManagedIdentityClientId
}

if (-not $token) {
    throw 'Failed to acquire Azure AD access token. Provide -AccessToken, service principal parameters, or run on an Azure resource with managed identity.'
}

Install-MailKitAssemblies

$message = [MimeKit.MimeMessage]::new()
$message.From.Add([MimeKit.MailboxAddress]::Parse($Sender))
$message.To.Add([MimeKit.MailboxAddress]::Parse($Recipient))
$message.Subject = $Subject
$bodyBuilder = [MimeKit.BodyBuilder]::new()
$bodyBuilder.TextBody = $Body
$message.Body = $bodyBuilder.ToMessageBody()

$smtpClient = [MailKit.Net.Smtp.SmtpClient]::new()
try {
    $smtpClient.Timeout = $TimeoutSeconds * 1000
    $smtpClient.Connect($SmtpHost, $Port, [MailKit.Security.SecureSocketOptions]::StartTls)
    $sasl = New-Object MailKit.Security.SaslMechanismOAuth2($SmtpUsername, $token)
    Write-Verbose "Authenticating to SMTP server as $SmtpUsername using OAuth2..."
    $smtpClient.Authenticate($sasl)
    Write-Verbose "Sending email from $Sender to $Recipient..."
    $smtpClient.Send($message)
    Write-Host 'Email sent successfully using passwordless SMTP.' -ForegroundColor Green
}
catch {
    Write-Host 'Failed to send email via SMTP.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.Exception.InnerException.Message -ForegroundColor Red
    exit 1
} finally {
    if ($smtpClient.IsConnected) {
        $smtpClient.Disconnect($true)
    }
    $smtpClient.Dispose()
}
