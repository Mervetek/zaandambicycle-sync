# SALT-OKUNUR: cok-varyantli (cok bedenli) aktif bisikletlerde varyantlar arasi FIYAT farki var mi?
# Kullanici beklentisi: inç/bedene gore fiyat degisir. Accell'de degismiyor gorunuyor - tum markalarda oyle mi?
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h=@{"X-Shopify-Access-Token"=$tok}
$multi=@()
$url="https://$shop/admin/api/$api/products.json?limit=250&status=active&fields=id,title,vendor,tags,options,variants"
while($url){
  $resp=Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
  foreach($p in (($resp.Content|ConvertFrom-Json).products)){
    if("$($p.tags)" -match "Accu's en Laders"){continue}
    $vs=@($p.variants); if($vs.Count -lt 2){continue}
    # beden secenegi var mi (Framehoogte/Maat/Wielmaat)?
    $hasSize = @($p.options | Where-Object { $_.name -match 'hoogte|maat|Maat|size|wiel' }).Count -gt 0
    $prices=@($vs | ForEach-Object {[double]$_.price} | Sort-Object -Unique)
    $multi+=[PSCustomObject]@{vendor="$($p.vendor)"; title=$p.title; varyant=$vs.Count; hasSize=$hasSize; farkliFiyat=$prices.Count; min=$prices[0]; max=$prices[-1]; spread=[math]::Round($prices[-1]-$prices[0],2)}
  }
  $url=$null; if(("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"'){$url=$Matches[1]}
  Start-Sleep -Milliseconds 300
}
$sizeProds=@($multi | Where-Object {$_.hasSize})
Write-Host "cok-varyantli aktif bisiklet: $($multi.Count) | beden secenekli: $($sizeProds.Count)"
Write-Host ""
Write-Host "=== BEDEN SECENEKLI URUNLERDE FIYAT FARKI (marka bazinda) ==="
$sizeProds | Group-Object vendor | Sort-Object Count -Descending | ForEach-Object {
  $g=$_.Group; $varies=@($g | Where-Object {$_.spread -gt 0})
  Write-Host ("  {0,-12} urun:{1,-4} bedene gore fiyat DEGISEN:{2,-4} sabit:{3}" -f $_.Name,$g.Count,$varies.Count,($g.Count-$varies.Count))
}
Write-Host ""
Write-Host "=== FIYATI BEDENE GORE DEGISEN ORNEKLER (varsa) ==="
@($sizeProds | Where-Object {$_.spread -gt 0} | Sort-Object spread -Descending | Select-Object -First 15) | ForEach-Object {
  Write-Host ("  [{0}] {1} | {2}-{3} EU (fark {4})" -f $_.vendor,$_.title,$_.min,$_.max,$_.spread)
}
$tot=@($sizeProds); $chg=@($sizeProds|Where-Object{$_.spread -gt 0})
Write-Host ""
Write-Host ("OZET: beden secenekli {0} urunun {1}'inde fiyat bedene gore DEGISIYOR, {2}'inde SABIT." -f $tot.Count,$chg.Count,($tot.Count-$chg.Count))
