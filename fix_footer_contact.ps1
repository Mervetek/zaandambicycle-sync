# Footer customer_support blogunu Hollandaca + gercek adres/acilis saatleriyle guncelle.
# KRITIK: PUT UTF-8 BYTE ile. Once yedek.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h=@{"X-Shopify-Access-Token"=$tok}
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $h).themes
$main=($themes|?{$_.role -eq 'main'})
$key='sections/footer-group.json'
$val=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $h).asset.value
$eu8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "theme\sections__footer-group.json.bak"),$val,$eu8)

# 1) baslik -> Klantenservice
$val=$val.Replace('"title": "Customer support"','"title": "Klantenservice"')
# 2) extra_customer_support -> NL adres + openingstijden
$html='<p><strong>Zaandam Bicycle</strong><br>Langeweide 101 (Winkelcentrum Westerwatering)<br>1507 NC Zaandam</p><p><strong>Openingstijden</strong><br>Maandag: 13:00-18:00 uur<br>Dinsdag t/m zaterdag: 09:00-18:00 uur<br>Zondag: gesloten</p>'
$val=[regex]::Replace($val, '"extra_customer_support":\s*"(?:[^"\\]|\\.)*"', ('"extra_customer_support": ' + ($html | ConvertTo-Json)))

$body=@{ asset=@{ key=$key; value=$val } } | ConvertTo-Json -Depth 6
$null=Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
Start-Sleep -Seconds 2
$chk=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $h).asset.value
Write-Host ("Klantenservice basligi: {0}" -f ($chk -match 'Klantenservice'))
Write-Host ("adres yazildi: {0}" -f ($chk -match 'Langeweide 101'))
Write-Host ("openingstijden yazildi: {0}" -f ($chk -match 'Openingstijden'))
Write-Host ("eski Ingilizce metin kaldi mi: {0}" -f ($chk -match 'Available between'))
