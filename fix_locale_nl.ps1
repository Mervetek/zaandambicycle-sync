# nl.json mojibake duzeltme: categorie[FFFD]n -> categorieen (dogru ë) + "all"->"alle" yazim hatasi
# KRITIK: PUT UTF-8 BYTE ile (yoksa ë tekrar bozulur). Once yedek.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h=@{"X-Shopify-Access-Token"=$tok}
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $h).themes
$main=($themes | Where-Object { $_.role -eq 'main' })
$r=[char]0xFFFD
$esc=[regex]::Escape($r)
$key='locales/nl.json'
$asset=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $h).asset
$val=$asset.value
# yedek
$eu8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "theme\locales__nl.json.bak_pre_mojibakefix"),$val,$eu8)

$before=([regex]::Matches($val,$esc)).Count
# 1) "Bekijk all " -> "Bekijk alle " (yazim hatasi)
$val=$val.Replace("Bekijk all categori","Bekijk alle categori")
# 2) categorie?[FFFD]n -> categorieën (buyuk/kucuk C korunur, e opsiyonel)
$val=[regex]::Replace($val, "Categorie?$esc"+"n", ("Categorie" + [char]0xEB + "n"))
$val=[regex]::Replace($val, "categorie?$esc"+"n", ("categorie" + [char]0xEB + "n"))
$after=([regex]::Matches($val,$esc)).Count
Write-Host ("bozuk karakter: once $before -> sonra $after")

# PUT: UTF-8 BYTE ile (charset=utf-8)
$body=@{ asset=@{ key=$key; value=$val } } | ConvertTo-Json -Depth 5
$null=Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
Write-Host "PUT tamam. dogrulama icin yeniden cekiliyor..."
Start-Sleep -Seconds 2
$chk=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $h).asset.value
$rem=([regex]::Matches($chk,$esc)).Count
foreach($m in [regex]::Matches($chk,'"[^"]*[Cc]ategori[^"]*"')){ Write-Host ("   {0}" -f $m.Value) }
Write-Host ("kalan bozuk karakter: {0}" -f $rem)
