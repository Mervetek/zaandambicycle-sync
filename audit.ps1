# BAGIMSIZ DENETIM (salt okunur - hicbir sey degistirmez)
# Taze tedarikci verisini ceker, Shopify'in MEVCUT durumuyla alan alan karsilastirir.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# ---------- 1) SHOPIFY mevcut durum ----------
$store = @{}
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,title,status,tags,variants,images"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            # VARYANT SEVIYESI: birlesik beden+renk urunlerinde her varyant ayri SKU tasir (2026-07-06)
            foreach ($v in @($p.variants)) {
                $s = "$($v.sku)".Trim()
                if ($s -and -not $store.ContainsKey($s)) {
                    $store[$s] = [PSCustomObject]@{ id = $p.id; title = $p.title; status = $p.status; qty = [int]$v.inventory_quantity; price = [double]$v.price; tags = $p.tags; barcode = "$($v.barcode)".Trim(); hasImg = (@($p.images).Count -gt 0) }
                }
            }
        }
        $url = $null
        if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}
Write-Host "shopify: $($store.Count) urun okundu"

# ---------- 2) KRUITBOSCH taze ----------
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
$kp = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=true&ExcludeBlocked=true&IncludeAttributes=false&IncludeAdditionalImages=false&IncludeOriginalImages=false&IncludeInActive=false" -Headers $kh -TimeoutSec 300
$kbAdvies = @{}; foreach ($p in $kp.Products) { $c = "$($p.ProductCode)".Trim(); if ($c -and $p.RecommendedSalesPrice) { $kbAdvies[$c] = [double]$p.RecommendedSalesPrice } }
$codes = @($kp.Products | ForEach-Object { "$($_.ProductCode)".Trim() } | Where-Object { $_ })
# C-kod aksesuarlar (Cortina aku/lader) da denetim kapsaminda
$ccPath = "$dataDir\kruitbosch_ccode_katalog.csv"
if (Test-Path $ccPath) {
    $ccK = Import-Csv $ccPath
    $codes += @($ccK.code | Where-Object { $_ })
    foreach ($k in $ccK) { $adv = [double]("$($k.advies)" -replace ',', '.'); if ($k.code -and $adv -gt 0 -and -not $kbAdvies.ContainsKey($k.code)) { $kbAdvies[$k.code] = $adv } }
}
$kbStock = @{}
for ($i = 0; $i -lt $codes.Count; $i += 100) {
    $batch = $codes[$i..([Math]::Min($i+99, $codes.Count-1))]
    $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($batch -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
    foreach ($s in $r.StocksAndPrices) {
        # GERCEK adet: StockQuantity (bayi ile birebir); Availability sadece stokta/degil kapisi (2026-07-07)
        $av = [int]$s.AvailabilityId
        $sq = 0; if ($null -ne $s.StockQuantity) { $sq = [int]$s.StockQuantity }
        $kbStock["$($s.ProductCode)".Trim()] = if ($av -in 1, 2) { if ($sq -gt 0) { $sq } elseif ($av -eq 1) { 10 } else { 2 } } else { 0 }
    }
    Start-Sleep -Milliseconds 350
}
Write-Host "kruitbosch taze: $($kbStock.Count) stok kaydi"

# ---------- 3) ACCELL taze ----------
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$accSkus = @($store.Keys | Where-Object { -not $kbStock.ContainsKey($_) })
$acc = @{}
for ($i = 0; $i -lt $accSkus.Count; $i += 20) {
    $batch = @($accSkus[$i..([Math]::Min($i+19, $accSkus.Count-1))])
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($c in $batch) { $a = $r.result.PSObject.Properties[$c]; if ($a -and $a.Value) { $acc[$c] = $a.Value } }
    } catch { }
    Start-Sleep -Milliseconds 300
}
Write-Host "accell taze: $($acc.Count) kayit"

# ---------- 4) KARSILASTIR ----------
$mismatch = New-Object System.Collections.ArrayList
$checked = 0; $noData = 0
foreach ($sku in $store.Keys) {
    $sp = $store[$sku]
    # beklenen adet
    $expQty = $null
    if ($kbStock.ContainsKey($sku)) {
        $expQty = $kbStock[$sku]   # StockQuantity bazli gercek adet (2026-07-07)
    } elseif ($acc.ContainsKey($sku)) {
        $a = $acc[$sku]
        $expQty = 0
        if ([int]$a.stock_status -le 2) { $expQty = if ([int]$a.stock -gt 0) { [int]$a.stock } else { 5 } }
    } else { $noData++; continue }
    $checked++
    # a) adet
    if ($sp.qty -ne $expQty) {
        [void]$mismatch.Add([PSCustomObject]@{ sku = $sku; urun = $sp.title; alan = 'stok_adedi'; shopify = $sp.qty; beklenen = $expQty })
    }
    # b) durum: fiyatli VE GORSELLI urun yayinda (stoksuz = qty 0, gorunur ama satin alinamaz) - politika 2026-07-05
    # taslak sadece fiyatsiz VEYA gorselsizler (gorselsizleri Flow #2 zaten taslakta tutar); gorsel kontrolu 2026-07-30 eklendi
    $expStatus = if ($sp.price -gt 0 -and $sp.hasImg) { 'active' } else { 'draft' }
    if ($sp.status -ne $expStatus) {
        [void]$mismatch.Add([PSCustomObject]@{ sku = $sku; urun = $sp.title; alan = 'durum'; shopify = $sp.status; beklenen = $expStatus })
    }
    # c) fiyat ust siniri (advies ustune satis olmamali - kullanici karari)
    if ($kbAdvies.ContainsKey($sku) -and $sp.price -gt ($kbAdvies[$sku] + 1)) {
        [void]$mismatch.Add([PSCustomObject]@{ sku = $sku; urun = $sp.title; alan = 'fiyat_advies_ustu'; shopify = $sp.price; beklenen = $kbAdvies[$sku] })
    }
    if ($acc.ContainsKey($sku)) {
        $rp = $acc[$sku].retail_price.value
        if ($rp -and $sp.price -gt ([double]$rp + 1)) {
            [void]$mismatch.Add([PSCustomObject]@{ sku = $sku; urun = $sp.title; alan = 'fiyat_advies_ustu'; shopify = $sp.price; beklenen = [double]$rp })
        }
    }
}
# ---------- 4.5) AKU SECENEKLERI (specs.battery_options) ----------
# Flex bisikletlerde: duplike secenek, included=true, bedava aku, tedarikcide olmayan aku (musteri sikayeti 2026-07-06)
$eanArt = @{}; foreach ($sku in $store.Keys) { $bc = $store[$sku].barcode; if ($bc) { $eanArt[$bc] = $sku } }
$batChecked = 0
$cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $gql = '{ "query": "query { products(first: 250, query: \"status:active\"' + $after + ') { pageInfo { hasNextPage endCursor } edges { node { title variants(first: 1) { edges { node { sku } } } bat: metafield(namespace: \"specs\", key: \"battery_options\") { value } } } } }" }'
    $rq = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 90
    $pg = $rq.data.products
    foreach ($e in $pg.edges) {
        $n = $e.node
        if (-not $n.bat) { continue }
        $bsku = "$($n.variants.edges[0].node.sku)".Trim()
        # PS 5.1 tuzagi: ConvertFrom-Json diziyi sarar - zorla enumerate et
        $opts = @()
        try { $opts = @((ConvertFrom-Json -InputObject "$($n.bat.value)") | ForEach-Object { $_ }) } catch { continue }
        $bcs = @($opts | ForEach-Object { "$($_.barcode)".Trim() } | Where-Object { $_ })
        if (-not $bcs.Count) { continue }   # KB sabit aku (barkodsuz tek kayit) - kapsam disi
        $batChecked++
        if (@($bcs | Group-Object | Where-Object { $_.Count -gt 1 }).Count) {
            [void]$mismatch.Add([PSCustomObject]@{ sku = $bsku; urun = $n.title; alan = 'aku_duplike'; shopify = ($bcs -join '/'); beklenen = 'benzersiz' })
        }
        # FIYAT MODELI v2 (2026-07-06): baz aku (EN DUSUK kapasite) dahil/0 olmali; ust kapasitede dahil/0 HATA
        $minCap = (@($opts | ForEach-Object { [int]$_.capacity_wh }) | Measure-Object -Minimum).Minimum
        foreach ($o in $opts) {
            $obc = "$($o.barcode)".Trim(); if (-not $obc) { continue }
            if (($o.included -eq $true -or [double]$o.additional_cost -eq 0) -and [int]$o.capacity_wh -ne $minCap) {
                [void]$mismatch.Add([PSCustomObject]@{ sku = $bsku; urun = $n.title; alan = 'aku_eski_model'; shopify = "$($o.capacity_wh)Wh dahil/0 (baz degil)"; beklenen = 'fark ucreti (baz=' + $minCap + 'Wh)' })
            }
            if ($eanArt.ContainsKey($obc) -and $acc.ContainsKey($eanArt[$obc])) {
                $ast = [int]$acc[$eanArt[$obc]].stock_status
                # stoksuz aku (baz DAHIL) available=false + gri cizilmeli (2026-07-07: baz aku de denetlenir,
                # onceden included haric tutuluyordu -> 625Wh baz aku stoksuz hatasi kacmisti)
                if ($ast -gt 2 -and $o.available -ne $false) {
                    [void]$mismatch.Add([PSCustomObject]@{ sku = $bsku; urun = $n.title; alan = 'aku_stoksuz_secenek'; shopify = "$($o.capacity_wh)Wh (st$ast)"; beklenen = 'available=false olmali' })
                }
            }
        }
    }
    $cursor = $pg.pageInfo.endCursor
    Start-Sleep -Milliseconds 300
} while ($pg.pageInfo.hasNextPage)
Write-Host "aku secenegi denetlenen (Flex): $batChecked"

Write-Host ""
Write-Host "=============== DENETIM SONUCU ==============="
Write-Host "kontrol edilen urun : $checked"
Write-Host "veri kaynagi olmayan: $noData"
Write-Host "UYUSMAZLIK          : $($mismatch.Count)"
if ($mismatch.Count) {
    $mismatch | Group-Object alan | Format-Table Name, Count -AutoSize
    $mismatch | Export-Csv "$dataDir\denetim_uyusmazlik.csv" -NoTypeInformation -Encoding utf8
    $mismatch | Select-Object -First 15 | Format-Table sku, alan, shopify, beklenen -AutoSize
}

# ---------- 5) rastgele ornek listesi (elle kontrol icin) ----------
$rnd = New-Object System.Random(20260705)
$sample = @($store.Keys | Where-Object { $kbStock.ContainsKey($_) -or $acc.ContainsKey($_) } | Sort-Object { $rnd.Next() } | Select-Object -First 15)
$sampleRows = foreach ($sku in $sample) {
    $sp = $store[$sku]
    [PSCustomObject]@{
        artikel_no = $sku
        urun = $sp.title
        kaynak = if ($kbStock.ContainsKey($sku)) { 'Kruitbosch portali' } else { 'Accentry portali' }
        shopify_durum = $sp.status
        shopify_adet = $sp.qty
        shopify_fiyat = $sp.price
        shopify_link = "https://admin.shopify.com/store/8t0pzm-g1/products/$($sp.id)"
    }
}
$sampleRows | Export-Csv "$dataDir\elle_kontrol_listesi.csv" -NoTypeInformation -Encoding utf8
Write-Host ""
Write-Host "elle kontrol listesi: data\elle_kontrol_listesi.csv (15 rastgele urun)"
