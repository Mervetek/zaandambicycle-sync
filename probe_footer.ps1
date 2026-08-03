# SALT-OKUNUR: tema footer + index bolumlerini ve sayfalari (scope varsa) tara -> bos alanlar
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h=@{"X-Shopify-Access-Token"=$tok}
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $h).themes
$main=($themes | Where-Object { $_.role -eq 'main' })
# footer group / settings_data
foreach($key in 'config/settings_data.json','sections/footer-group.json'){
  try {
    $a=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $h).asset
    if($a.value){ Write-Host ("--- {0} ({1} kar) ---" -f $key,$a.value.Length)
      # menu / link_list / text / title referanslari
      foreach($m in [regex]::Matches($a.value,'"(menu|title|heading|text|subtext|content|link_list)"\s*:\s*"([^"]{0,80})"')){ Write-Host ("   {0} = {1}" -f $m.Groups[1].Value,$m.Groups[2].Value) }
    }
  } catch { Write-Host "$key yok" }
}
# menuler
try { $navs=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/menus.json" -Headers $h).menus; Write-Host "menuler: $($navs.title -join ', ')" } catch { Write-Host "menus API yok (scope)" }
