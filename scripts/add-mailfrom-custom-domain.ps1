<#!
.SYNOPSIS
Create a MailFrom address (sender username) for a custom domain in Azure Communication Services.

.DESCRIPTION
Creates a sender username on an existing custom email domain in Azure Communication Services.
The custom domain must already be added and verified before running this script.

Prerequisites:
- Custom domain must be added to the Email Service
- Domain must be verified (DNS records configured)
- You must be logged in with Azure PowerShell (Connect-AzAccount)

.PARAMETER EmailServiceName
The name of the Azure Email Communication Service resource.

.PARAMETER CustomDomainName
The custom domain name (e.g., "contoso.com").

.PARAMETER SenderUsername
The local part of the email address (e.g., "noreply" for noreply@contoso.com).

.PARAMETER DisplayName
The display name for the sender (optional, defaults to SenderUsername).

.PARAMETER ResourceGroupName
The resource group containing the Email Service.

.PARAMETER SubscriptionId
The Azure subscription ID (optional, uses current context if not provided).

.EXAMPLE
# Create noreply@contoso.com
./add-mailfrom-custom-domain.ps1 `
    -EmailServiceName "acs-smtp-poc-email" `
    -CustomDomainName "contoso.com" `
    -SenderUsername "noreply" `
    -ResourceGroupName "rg-acs-smtp"

.EXAMPLE
# Create marketing@contoso.com with a display name
./add-mailfrom-custom-domain.ps1 `
    -EmailServiceName "acs-smtp-poc-email" `
    -CustomDomainName "contoso.com" `
    -SenderUsername "marketing" `
    -DisplayName "Marketing Team" `
    -ResourceGroupName "rg-acs-smtp" `
    -SubscriptionId "00000000-0000-0000-0000-000000000000"

.NOTES
Reference: https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-custom-verified-domains
and https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-multiple-senders?pivots=platform-azp
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$EmailServiceName,

    [Parameter(Mandatory = $true)]
    [string]$CustomDomainName,

    [Parameter(Mandatory = $true)]
    [string]$SenderUsername,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$DisplayName,

    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Check for required modules
$requiredModules = @('Az.Accounts', 'Az.Communication')
foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        throw "Required module '$moduleName' is missing. Install it with: Install-Module $moduleName -Scope CurrentUser"
    }
}

# Use provided display name or default to sender username
if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    $DisplayName = $SenderUsername
}

Write-Host "Creating MailFrom address for custom domain..." -ForegroundColor Cyan
Write-Host "  Email Service: $EmailServiceName" -ForegroundColor Gray
Write-Host "  Custom Domain: $CustomDomainName" -ForegroundColor Gray
Write-Host "  Sender Username: $SenderUsername" -ForegroundColor Gray
Write-Host "  Display Name: $DisplayName" -ForegroundColor Gray
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host ""

# Set subscription context if provided
if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Write-Verbose "Setting subscription context to: $SubscriptionId"
    $null = Set-AzContext -SubscriptionId $SubscriptionId
}

# Get current subscription context
$context = Get-AzContext
if (-not $context) {
    throw "No Azure context found. Please run Connect-AzAccount first."
}

Write-Host "Using subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Gray
Write-Host ""

# Verify the Email Service exists
Write-Verbose "Verifying Email Service exists..."
try {
    $emailService = Get-AzEmailService -Name $EmailServiceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    Write-Verbose "Email Service found: $($emailService.Id)"
} catch {
    throw "Email Service '$EmailServiceName' not found in resource group '$ResourceGroupName'. Error: $_"
}

# Verify the custom domain exists and is verified
Write-Verbose "Verifying custom domain exists and is verified..."
try {
    $domain = Get-AzEmailServiceDomain -EmailServiceName $EmailServiceName -DomainName $CustomDomainName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    
    if ($domain.DomainManagement -ne 'CustomerManaged') {
        throw "Domain '$CustomDomainName' is not a customer-managed domain. Domain management type: $($domain.DomainManagement)"
    }
    
    if ($domain.VerificationState -ne 'Verified') {
        Write-Warning "Domain verification state: $($domain.VerificationState)"
        Write-Warning "The domain may not be fully verified. Email sending might fail."
        Write-Warning "Ensure DNS records are properly configured."
    } else {
        Write-Verbose "Domain is verified and ready to use."
    }
} catch {
    throw "Custom domain '$CustomDomainName' not found in Email Service '$EmailServiceName'. Error: $_"
}

# Check if sender username already exists
Write-Verbose "Checking if sender username already exists..."
$existingSender = Get-AzEmailServiceSenderUsername `
    -EmailServiceName $EmailServiceName `
    -DomainName $CustomDomainName `
    -ResourceGroupName $ResourceGroupName `
    -SenderUsername $SenderUsername `
    -ErrorAction SilentlyContinue

if ($existingSender) {
    Write-Host "Sender username already exists!" -ForegroundColor Yellow
    Write-Host "  Email Address: $SenderUsername@$CustomDomainName" -ForegroundColor Yellow
    Write-Host "  Display Name: $($existingSender.DisplayName)" -ForegroundColor Yellow
    Write-Host "  Username: $($existingSender.Username)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No changes made. Use Remove-AzEmailServiceSenderUsername to delete it first if you want to recreate it." -ForegroundColor Yellow
    return
}

# Create the sender username
Write-Host "Creating sender username..." -ForegroundColor Cyan
try {
    $newSender = New-AzEmailServiceSenderUsername `
        -EmailServiceName $EmailServiceName `
        -DomainName $CustomDomainName `
        -ResourceGroupName $ResourceGroupName `
        -SenderUsername $SenderUsername `
        -Username $DisplayName `
        -DisplayName $DisplayName `
        -ErrorAction Stop
    
    Write-Host "✓ Successfully created MailFrom address!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Sender Details:" -ForegroundColor Cyan
    Write-Host "  Email Address: $SenderUsername@$CustomDomainName" -ForegroundColor Green
    Write-Host "  Display Name: $($newSender.DisplayName)" -ForegroundColor Gray
    Write-Host "  Username: $($newSender.Username)" -ForegroundColor Gray
    Write-Host "  Resource ID: $($newSender.Id)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "You can now use this email address as the sender in your SMTP scripts." -ForegroundColor Cyan
    
    # Return the sender object
    return $newSender
    
} catch {
    Write-Error "Failed to create sender username: $_"
    throw
}
