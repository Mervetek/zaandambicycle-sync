# SALT-OKUNUR: canli tema locale + sayfalar + politikalar durumu (mojibake + bos icerik taramasi)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h=@{"X-Shopify-Access-Token"=$tok}

Write-Host "=== SAYFALAR (pages) ==="
$pages=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/pages.json?limit=250" -Headers $h).pages
foreach($p in $pages){ $len=("$($p.body_html)").Length; Write-Host ("  [{0}] '{1}' (handle:{2}) icerik:{3} kar" -f $p.id,$p.title,$p.handle,$len) }
if(-not $pages){ Write-Host "  (hic sayfa yok)" }

Write-Host ""
Write-Host "=== POLITIKALAR (shop policies) ==="
$pol=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/policies.json" -Headers $h).policies
foreach($p in $pol){ Write-Host ("  {0}: {1} kar" -f $p.title,("$($p.body)").Length) }
if(-not $pol){ Write-Host "  (politika yok)" }

Write-Host ""
Write-Host "=== SHOP ILETISIM BILGISI ==="
$s=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/shop.json" -Headers $h).shop
"  name={0}" -f $s.name
"  email={0} | customer_email={1}" -f $s.email,$s.customer_email
"  phone={0}" -f $s.phone
"  adres={0} {1} {2} {3} {4}" -f $s.address1,$s.zip,$s.city,$s.province,$s.country_name

Write-Host ""
Write-Host "=== CANLI nl.json locale: 'categori' + bozuk karakter ==="
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $h).themes
$main=$themes | Where-Object { $_.role -eq 'main' }
Write-Host ("main tema: {0} ({1})" -f $main.name,$main.id)
try {
  $asset=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=locales/nl.json" -Headers $h).asset
  $val=$asset.value
  $repl=[regex]::Matches($val,'.{20}�.{20}')
  Write-Host ("nl.json boyut:{0} | replacement-char sayisi:{1}" -f $val.Length,$repl.Count)
  foreach($m in ($repl | Select-Object -First 20)){ Write-Host ("   MOJIBAKE: ...{0}..." -f ($m.Value -replace '\s+',' ')) }
  # categori gecen satirlar
  foreach($m in [regex]::Matches($val,'"[^"]*[Cc]ategori[^"]*"')){ Write-Host ("   categori: {0}" -f $m.Value) }
} catch { Write-Host "nl.json cekilemedi: $_" }
