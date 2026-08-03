# SALT-OKUNUR: canli product.json'i kaydet + KULMdX custom_liquid blogunu goster + hedef Cortina sayisi
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hr=@{"X-Shopify-Access-Token"=$tok}
$hg=@{"X-Shopify-Access-Token"=$tok; "Content-Type"="application/json"}
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $hr).themes
$main=($themes|?{$_.role -eq 'main'})
$pj=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=templates/product.json" -Headers $hr).asset.value
$eu8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "theme\templates__product.json.live"),$pj,$eu8)
Write-Host ("product.json kaydedildi: {0} kar" -f $pj.Length)
$obj=$pj | ConvertFrom-Json
# main-product section bloklari
$mp=$obj.sections.PSObject.Properties | Where-Object { $_.Value.type -match 'main-product|product' } | Select-Object -First 1
Write-Host ("main section: {0} (type {1})" -f $mp.Name,$mp.Value.type)
foreach($b in $mp.Value.blocks.PSObject.Properties){
  $bt=$b.Value.type
  $cl=$b.Value.settings.custom_liquid
  Write-Host ("  block {0} type={1} custom_liquid_uzunluk={2}" -f $b.Name,$bt,("$cl").Length)
}
# KULMdX bul ve liquid'i dosyaya yaz
$kul=$mp.Value.blocks.PSObject.Properties | Where-Object { $_.Name -match 'KULMdX' -or ("$($_.Value.settings.custom_liquid)" -match 'battery_options|bc-selector|b\.capacity_wh') } | Select-Object -First 1
if($kul){
  Write-Host ""
  Write-Host ("=== SECICI BLOK: {0} ===" -f $kul.Name)
  [IO.File]::WriteAllText((Join-Path $PSScriptRoot "theme\kulmdx_liquid.txt"),"$($kul.Value.settings.custom_liquid)",$eu8)
  Write-Host "liquid -> theme\kulmdx_liquid.txt"
}
# Hedef Cortina: aktif, vendor Cortina, battery_options dolu
$targets=@(); $after=$null; $more=$true
while($more){
  $q='{"query":"{ products(first:100, query:\"vendor:Cortina status:active\"'+$(if($after){', after:\"'+$after+'\"'}else{''})+') { pageInfo{hasNextPage endCursor} edges{ node{ id title tags bo:metafield(namespace:\"specs\",key:\"battery_options\"){value type} co:metafield(namespace:\"specs\",key:\"charger_options\"){value type} } } } }"}'
  $r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hg -Body ([Text.Encoding]::UTF8.GetBytes($q))
  if($r.errors){ Write-Host "ERR: $($r.errors.message -join '; ')"; break }
  foreach($e in $r.data.products.edges){
    $n=$e.node; $bv="$($n.bo.value)".Trim()
    $hasSel = $bv -and $bv -ne '[]'
    if($hasSel){ $targets+=[pscustomobject]@{id=$n.id; title=$n.title; boType=$n.bo.type; coType=$n.co.type; hasTag=($n.tags -contains 'accu-op-aanvraag')} }
  }
  $more=$r.data.products.pageInfo.hasNextPage; $after=$r.data.products.pageInfo.endCursor
}
Write-Host ""
Write-Host ("HEDEF Cortina e-bike (battery_options dolu): {0}" -f $targets.Count)
Write-Host ("  battery_options type ornegi: {0} | charger type: {1}" -f ($targets[0].boType),($targets[0].coType))
$targets | Select-Object -First 5 | ForEach-Object { Write-Host ("   - {0}" -f $_.title) }
$targets | Export-Csv (Join-Path $PSScriptRoot "data\cortina_form_hedef.csv") -NoTypeInformation -Encoding utf8
Write-Host "hedef liste -> data\cortina_form_hedef.csv"
