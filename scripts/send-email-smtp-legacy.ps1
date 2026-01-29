<#!
.SYNOPSIS
Send a basic test email through Azure Communication Services (ACS) SMTP using username/password authentication.

.DESCRIPTION
Retrieves the SMTP client secret from Azure Key Vault (recommended) or accepts it as a SecureString parameter, builds a NetworkCredential, and submits a simple text email via smtp.azurecomm.net using STARTTLS on port 587.

Based on the ACS SMTP guidance: https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/send-email-smtp/smtp-authentication

.EXAMPLE
./send-email-smtp-legacy.ps1 `
    -SubscriptionId "00000000-0000-0000-0000-000000000000" `
    -KeyVaultName "kv-acs-smtp-poc" `
    -SecretName "smtp-legacy-client-secret" `
    -SmtpUsername "legacy-client@74b28d60-a8e2-48d6-a903-8f5771b8a3c7.azurecomm.net" `
    -Sender "legacy-client@74b28d60-a8e2-48d6-a903-8f5771b8a3c7.azurecomm.net" `
    -Recipient "user@contoso.com"

./send-email-smtp-legacy.ps1 `
    -SubscriptionId "1ab5dc89-603c-4f45-bdd1-a4231369b400" `
    -KeyVaultName "kv-acs-smtp-poc" `
    -SecretName "smtp-legacy-client-secret" `
    -SmtpUsername "legacy-client@74b28d60-a8e2-48d6-a903-8f5771b8a3c7.azurecomm.net" `
    -Sender "noreply@74b28d60-a8e2-48d6-a903-8f5771b8a3c7.azurecomm.net" `
    -Recipient "chad.voelker@gmail.com"

./send-email-smtp-legacy.ps1 `
    -SubscriptionId "1ab5dc89-603c-4f45-bdd1-a4231369b400" `
    -KeyVaultName "kv-acs-smtp-poc" `
    -SecretName "smtp-legacy-client-secret" `
    -SmtpUsername "legacy-client@74b28d60-a8e2-48d6-a903-8f5771b8a3c7.azurecomm.net" `
    -Sender "legacy-client@74b28d60-a8e2-48d6-a903-8f5771b8a3c7.azurecomm.net" `
    -Recipient "chad.voelker@microsoft.com" `
    -Verbose

.NOTES
- Ensure you have network access to the KeyVault and smtp.azurecomm.net (port 587).

#>


[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$SmtpUsername,

    [Parameter(Mandatory = $true)]
    [string]$Sender,

    [Parameter(Mandatory = $true)]
    [string]$Recipient,

    [string]$Subject = 'ACS SMTP Legacy Test',

    [string]$Body = 'Hello from Azure Communication Services SMTP using username/password.',

    [string]$SmtpHost = 'smtp.azurecomm.net',

    [int]$Port = 587,

    [switch]$SkipCertificateValidation,

    [string]$KeyVaultName,

    [string]$SecretName,

    [SecureString]$Password,

    [switch]$UseSsl = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ($Password) -and (-not $KeyVaultName -or -not $SecretName)) {
    throw 'Provide either -Password or both -KeyVaultName and -SecretName.'
}

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.KeyVault -ErrorAction Stop
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

function Get-PlainTextSecret {
    param([SecureString]$SecureValue)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

if (-not $Password) {
    Write-Verbose "Retriveing secret from Key Vault $KeyVaultName / $SecretName."
    $secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName
    if ($secret.SecretValue -is [SecureString]) {
        Write-Verbose "  Secret retrieved as SecureString."
        $Password = $secret.SecretValue
    }
    elseif ($secret.Value) {
        Write-Verbose "  Converting secret value to SecureString."
        $Password = ConvertTo-SecureString -String $secret.Value -AsPlainText -Force
    }
    else {
        throw "Secret '$SecretName' did not contain a retrievable value."
    }
}

$plainPassword = Get-PlainTextSecret -SecureValue $Password
Write-Verbose "  Retrieved password $($plainPassword.Substring(0,3))******************"

$mailMessage = New-Object System.Net.Mail.MailMessage($Sender, $Recipient, $Subject, $Body)
Write-Verbose "Created MailMessage from $Sender to $Recipient with subject '$Subject'."

$smtpClient = [System.Net.Mail.SmtpClient]::new($SmtpHost, $Port)
$smtpClient.EnableSsl = [bool]$UseSsl
Write-Verbose "Configured SmtpClient to connect to $($SmtpHost):$Port with SSL=$($smtpClient.EnableSsl)."

if ($SkipCertificateValidation) {
    Write-Verbose "Skipping certificate validation for SMTP connection."
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
$credential = New-Object System.Net.NetworkCredential($SmtpUsername, $plainPassword)
$smtpClient.Credentials = $credential

try {
    Write-Host "Sending email via $($SmtpHost):$Port as $SmtpUsername" -ForegroundColor Cyan
    
    $smtpClient.Send($mailMessage)
    
    Write-Host 'Email sent successfully to SMTP server.' -ForegroundColor Green
    Write-Host "Check Azure Portal for delivery status: Communication Service > Monitoring > Insights > Email"
    Write-Host "Note: Email delivery can take a few minutes. Check spam/junk folders if not received." -ForegroundColor Yellow
}
catch {
    Write-Host 'Email failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "Inner Exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
    }
    Write-Verbose $_.Exception.StackTrace
    throw
}
finally {
    Write-Verbose 'Cleaning up.'
    $mailMessage.Dispose()
    $smtpClient.Dispose()
    if ($SkipCertificateValidation) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    }
    [Array]::Clear([char[]]$plainPassword, 0, $plainPassword.Length)
}
