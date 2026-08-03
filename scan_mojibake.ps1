# SALT-OKUNUR: canli locale'lerdeki bozuk karakter iceren string'leri listele (kod-noktasi ile, literal karakter YOK)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h=@{"X-Shopify-Access-Token"=$tok}
$repl=[char]0xFFFD
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $h).themes
$main=($themes | Where-Object { $_.role -eq 'main' })
# tema asset listesi (tum json/liquid locale)
$assets=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json" -Headers $h).assets
$keys=@($assets | Where-Object { $_.key -match '^locales/.*\.json$' } | ForEach-Object { $_.key })
Write-Host ("locale dosyalari: {0}" -f ($keys -join ', '))
foreach($key in $keys){
  try {
    $asset=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $h).asset
    if(-not $asset.value){ continue }
    $val=$asset.value
    $pat='"[^"]*'+[regex]::Escape($repl)+'[^"]*"'
    $bad=[regex]::Matches($val,$pat)
    if($bad.Count -gt 0){
      Write-Host ("=== {0} : {1} bozuk string ===" -f $key,$bad.Count)
      $seen=@{}
      foreach($m in $bad){ if(-not $seen.ContainsKey($m.Value)){ $seen[$m.Value]=1; Write-Host ("   {0}" -f ($m.Value -replace [regex]::Escape($repl),'[?]')) } }
    }
  } catch {}
}
Write-Host "tarama bitti"
