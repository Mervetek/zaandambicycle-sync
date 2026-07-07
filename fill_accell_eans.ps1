# Aktif urunlerde BOS olan varyant barkodlarini (EAN) Accell single_ean ile doldurur.
# Sebep (2026-07-07): Accell import'u barcode alanini yazmamis -> codes blogu EAN gostermiyor (473 varyant).
# Kruitbosch urunleri (Cortina/Alpina/Raleigh) zaten EAN'li; bu sadece Accell (Batavus/Sparta/Loekie...) icin.
# Idempotent: sadece barkodu bos olani doldurur. Accell'de EAN'i olmayan SKU'ya dokunmaz.
param([switch]$WhatIf)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $api='2024-10'
$sb=@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h=@{'X-Shopify-Access-Token'=$tok}; $hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}

# 1) bos barkodlu aktif varyantlar (legacy id + sku)
$targets=@(); $cursor=$null
do{
 $after= if($cursor){ ', after: \"'+$cursor+'\"' } else { '' }
 $q='{ "query": "query { products(first: 100, query: \"status:active\"'+$after+') { pageInfo{hasNextPage endCursor} edges { node { variants(first:50){ edges { node { legacyResourceId sku barcode } } } } } } }" }'
 $r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body $q -ContentType 'application/json' -TimeoutSec 60
 foreach($e in $r.data.products.edges){ foreach($v in $e.node.variants.edges){ $sku="$($v.node.sku)".Trim(); if($sku -and -not "$($v.node.barcode)".Trim()){ $targets += [pscustomobject]@{ id=$v.node.legacyResourceId; sku=$sku } } } }
 $cursor=$r.data.products.pageInfo.endCursor; $hn=$r.data.products.pageInfo.hasNextPage
}while($hn)
Write-Host "bos barkodlu varyant: $($targets.Count)"

# 2) Accell'den single_ean (20'li parti)
$ab=@{username=$env:ACCELL_USERNAME;password=$env:ACCELL_PASSWORD}|ConvertTo-Json
$atok=(Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah=@{ Authentication="Bearer $atok"; accept="application/json"; "X-version"="2.0" }
$skus=@($targets.sku | Select-Object -Unique)
$ean=@{}
for($i=0;$i -lt $skus.Count;$i+=20){
  $batch=$skus[$i..([Math]::Min($i+19,$skus.Count-1))]
  $qs=($batch|ForEach-Object{"c=$_"}) -join '&'
  try{
    $ah["fe-request-id"]=[guid]::NewGuid().ToString()
    $ar=Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$qs&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
    foreach($code in $batch){ $p=$ar.result.PSObject.Properties[$code]; if($p -and $p.Value.single_ean){ $ean[$code]="$($p.Value.single_ean)".Trim() } }
  }catch{ Write-Host "accell parti $i hata: $($_.Exception.Message)" }
  Start-Sleep -Milliseconds 300
}
Write-Host "Accell'de EAN bulunan SKU: $($ean.Count)/$($skus.Count)"

# 3) Shopify varyant barkodu yaz
$done=0; $noean=0; $err=0
foreach($t in $targets){
  if(-not $ean.ContainsKey($t.sku)){ $noean++; continue }
  if($WhatIf){ $done++; continue }
  $body=@{ variant=@{ id=[long]$t.id; barcode=$ean[$t.sku] } } | ConvertTo-Json
  for($try=1;$try -le 3;$try++){
    try{ $null=Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/variants/$($t.id).json" -Headers $hj -Body $body -TimeoutSec 60; $done++; break }
    catch{ $c=try{[int]$_.Exception.Response.StatusCode}catch{0}; if($c -eq 429 -and $try -lt 3){ Start-Sleep -Seconds 2 } else { $err++; break } }
  }
  Start-Sleep -Milliseconds 350
}
Write-Host "DONE. barkod yazilan: $done | Accell'de EAN yok: $noean | hata: $err"
