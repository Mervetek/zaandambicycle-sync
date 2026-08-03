# Cortina form alicisini test (gmail) -> canli (info@zaandambicycle.nl) cevir + aktivasyonu tetikle.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hr=@{"X-Shopify-Access-Token"=$tok}
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $hr).themes
$main=($themes|?{$_.role -eq 'main'})
$key='templates/product.json'
$old='mervetek.bilgmuh@gmail.com'
$new='info@zaandambicycle.nl'
$pj=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $hr).asset.value
$eu8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "theme\templates__product.json.bak_formlive"),$pj,$eu8)
$c=([regex]::Matches($pj,[regex]::Escape($old))).Count
Write-Host "test-mail bulunan yer: $c"
if($c -ne 1){ Write-Host "beklenen 1 degil - DUR"; return }
$pj2=$pj.Replace($old,$new)
try { $null=$pj2|ConvertFrom-Json; Write-Host "JSON gecerli" } catch { Write-Host "JSON BOZUK - DUR"; return }
$body=@{ asset=@{ key=$key; value=$pj2 } } | ConvertTo-Json -Depth 6
$null=Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json" -Headers $hr -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
Start-Sleep -Seconds 2
$chk=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $hr).asset.value
Write-Host ("canli mail var={0} | test mail kaldi mi={1}" -f ($chk -match 'info@zaandambicycle.nl'),($chk -match 'mervetek'))
