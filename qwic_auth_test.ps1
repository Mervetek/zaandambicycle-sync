# QWIC Auth0 PKCE akisi - tarayicisiz oturum testi (salt okunur; token alip API'yi yoklar)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dom = "https://qwic.eu.auth0.com"
$cid = "DtSqOKBuTsZ8uHZO1LNE2cuG8rbGJc1i"
$aud = "https://api.qwic.dk/v1/"
$redir = "https://dealer.qwic.nl/"
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
$cfg = @{}; Get-Content (Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\sync.env") | ForEach-Object { if ($_ -cmatch '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$user = $cfg.QWIC_USERNAME; $pass = $cfg.QWIC_PASSWORD
if (-not $user) { Write-Host "sync.env'de QWIC_USERNAME/QWIC_PASSWORD yok"; exit 1 }

# PKCE
$bytes = New-Object byte[] 32; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
$verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
$sha = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
$challenge = [Convert]::ToBase64String($sha).TrimEnd('=').Replace('+','-').Replace('/','_')
$state = [guid]::NewGuid().ToString('N')

$ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$authUrl = "$dom/authorize?client_id=$cid&response_type=code&redirect_uri=$([uri]::EscapeDataString($redir))&scope=$([uri]::EscapeDataString('openid profile email offline_access'))&audience=$([uri]::EscapeDataString($aud))&code_challenge=$challenge&code_challenge_method=S256&state=$state"
$r1 = Invoke-WebRequest -Uri $authUrl -WebSession $ws -UserAgent $UA -UseBasicParsing -TimeoutSec 60
$loginUri = $r1.BaseResponse.ResponseUri
Write-Host ("login sayfasi: " + $loginUri)
if ("$loginUri" -notmatch '/u/login') { Write-Host "beklenmeyen sayfa!"; ($r1.Content.Substring(0,[Math]::Min(500,$r1.Content.Length))); exit 1 }
$st2 = if ("$loginUri" -cmatch 'state=([^&]+)') { $Matches[1] } else { $state }

# login formunu POST'la (universal login: identifier+password tek form ya da iki adim)
$form = @{ state = $st2; username = $user; password = $pass; action = 'default' }
try {
    $r2 = Invoke-WebRequest -Uri "$dom/u/login?state=$st2" -Method Post -Body $form -WebSession $ws -UserAgent $UA -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 10
    $finalUri = "$($r2.BaseResponse.ResponseUri)"
} catch {
    # PS 5.1 http->https capraz redirect sorunlari icin elle takip gerekebilir
    Write-Host ("POST hata: " + $_.Exception.Message)
    $resp = $_.Exception.Response
    if ($resp -and $resp.Headers['Location']) { Write-Host ("Location: " + $resp.Headers['Location']) }
    exit 1
}
Write-Host ("son URL: " + $finalUri)
if ($finalUri -cmatch 'code=([^&]+)') {
    $code = $Matches[1]
    Write-Host "AUTH CODE alindi, token'a ceviriliyor..."
} elseif ($r2.Content -cmatch 'name="password"') {
    Write-Host "hala login formu - kimlik reddedildi ya da ek adim var"
    if ($r2.Content -cmatch '(?s)class="[^"]*error[^"]*"[^>]*>([^<]+)<') { Write-Host ("hata metni: " + $Matches[1].Trim()) }
    exit 1
} else {
    Write-Host ("code yok. govde basi: " + ($r2.Content.Substring(0,[Math]::Min(400,$r2.Content.Length)) -replace '\s+',' '))
    exit 1
}
$tb = @{ grant_type='authorization_code'; client_id=$cid; code=$code; code_verifier=$verifier; redirect_uri=$redir }
$tok = Invoke-RestMethod -Method Post -Uri "$dom/oauth/token" -Body $tb -TimeoutSec 30
Write-Host ("TOKEN OK | expires_in: " + $tok.expires_in + " | refresh_token: " + $(if ($tok.refresh_token) { 'VAR' } else { 'yok' }))
$tok | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data\qwic_token.json") -Encoding utf8

# API yoklamasi
$ah = @{ Authorization = "Bearer $($tok.access_token)" }
foreach ($ep in @('products','bikes','catalog/products','articles','stock')) {
    try {
        $rr = Invoke-RestMethod -Uri ("https://api.qwic.dk/v1/" + $ep) -Headers $ah -UserAgent $UA -TimeoutSec 30
        Write-Host ("API /" + $ep + " OK -> tip: " + $rr.GetType().Name)
        break
    } catch { Write-Host ("API /" + $ep + " : " + $_.Exception.Message) }
}
