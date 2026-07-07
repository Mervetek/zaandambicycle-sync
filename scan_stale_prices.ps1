# SALT-OKUNUR: aktif bisiklet fiyatlarini GUNCEL tedarikci advies'i ile karsilastirir.
# daily_sync fiyata dokunmadigi icin import-zamani fiyatlar bayatlayabilir (2026-07-07: CECOMM50L1002 2511 vs advies 2561).
# Sadece rapor; hicbir sey degistirmez. Aksesuar/aku urunlerini (Accu's en Laders) haric tutar.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $tok }
# Shopify: aktif varyant sku->price (aku/lader collection haric)
$store = @{}
$url = "https://$shop/admin/api/$api/products.json?limit=250&status=active&fields=id,title,tags,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
        if ("$($p.tags)" -match "Accu's en Laders") { continue }
        foreach ($v in @($p.variants)) { $s = "$($v.sku)".Trim(); if ($s -and -not $store.ContainsKey($s)) { $store[$s] = @{ title = $p.title; price = [double]$v.price } } }
    }
    $url = $null; if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
Write-Output "shopify aktif varyant: $($store.Count)"
# Kruitbosch advies
$kh = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)")) }
$kb = Invoke-RestMethod -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=true" -Headers $kh -TimeoutSec 300
$adv = @{}; foreach ($p in $kb.Products) { $c = "$($p.ProductCode)".Trim(); if ($c -and $p.RecommendedSalesPrice) { $adv[$c] = [double]$p.RecommendedSalesPrice } }
# Accell retail (KB'de olmayanlar)
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$accSkus = @($store.Keys | Where-Object { -not $adv.ContainsKey($_) })
for ($i = 0; $i -lt $accSkus.Count; $i += 20) {
    $batch = @($accSkus[$i..([Math]::Min($i+19, $accSkus.Count-1))]); $qs = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try { $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$qs&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($c in $batch) { $a = $r.result.PSObject.Properties[$c]; if ($a -and $a.Value.retail_price.value) { $adv[$c] = [double]$a.Value.retail_price.value } } } catch {}
    Start-Sleep -Milliseconds 300
}
# karsilastir
$below = @(); $above = @(); $match = 0; $noAdv = 0
foreach ($s in $store.Keys) {
    if (-not $adv.ContainsKey($s)) { $noAdv++; continue }
    $d = [math]::Round($adv[$s] - $store[$s].price, 2)
    if ($d -gt 1) { $below += [pscustomobject]@{ sku = $s; urun = $store[$s].title; bizde = $store[$s].price; advies = $adv[$s]; fark = $d } }
    elseif ($d -lt -1) { $above += [pscustomobject]@{ sku = $s; urun = $store[$s].title; bizde = $store[$s].price; advies = $adv[$s]; fark = $d } }
    else { $match++ }
}
$below | Sort-Object fark -Descending | Export-Csv "$dataDir\bayat_fiyat_advies_alti.csv" -NoTypeInformation -Encoding utf8
$above | Export-Csv "$dataDir\fiyat_advies_ustu.csv" -NoTypeInformation -Encoding utf8
Write-Output "=== FIYAT vs GUNCEL ADVIES ==="
Write-Output "eslesen: $match | advies YOK: $noAdv"
Write-Output "ADVIES ALTINDA (bayat/indirimli): $($below.Count) urun | toplam fark: $([math]::Round(($below | Measure-Object fark -Sum).Sum,2)) EU"
Write-Output "ADVIES USTUNDE (politika ihlali): $($above.Count)"
Write-Output "en cok fark (advies alti) ilk 12:"
$below | Sort-Object fark -Descending | Select-Object -First 12 | ForEach-Object { Write-Output ("  {0} | {1} -> advies {2} (fark {3})" -f $_.sku, $_.bizde, $_.advies, $_.fark) }
