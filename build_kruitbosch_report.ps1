$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$kb     = Get-Content "$dataDir\kruitbosch_products_raw.json" -Raw | ConvertFrom-Json
$stocks = Get-Content "$dataDir\kruitbosch_stocks_raw.json" -Raw | ConvertFrom-Json
$av     = Import-Csv "$dataDir\admin_variations.csv"
$ap     = Import-Csv "$dataDir\admin_products.csv"

$stockByCode = @{}
foreach ($s in $stocks) { $stockByCode["$($s.ProductCode)".Trim()] = $s }

function Get-Epoch($dateStr) {
    if ($dateStr -match '(\d{10,})') { return (Get-Date '1970-01-01').AddMilliseconds([double]$Matches[1]).ToString('yyyy-MM-dd') }
    return ''
}

# 1) Kruitbosch stok CSV'si (Shopify senkronu icin de temel)
$rows = foreach ($p in $kb) {
    $code = "$($p.ProductCode)".Trim()
    $s = $stockByCode[$code]
    $availId = if ($s) { $s.AvailabilityId } else { $null }
    $stokVar = if ($availId -eq 1 -or $availId -eq 2) { 'VAR' } else { 'YOK' }
    [PSCustomObject]@{
        sku = $code
        ean = $p.EANCode
        urun = $p.Description
        stok = if ($stokVar -eq 'VAR') { 1 } else { 0 }
        durum = if ($s) { $s.Availability } else { 'kayit yok' }
        stok_adet = if ($s -and $s.PSObject.Properties['StockQuantity']) { $s.StockQuantity } else { '' }
        gelis_tarihi = if ($s -and $s.PSObject.Properties['DateAvailable']) { Get-Epoch $s.DateAvailable } else { '' }
        alis_net = if ($s) { [math]::Round([double]$s.PriceNett, 2) } else { '' }
        alis_brut = if ($s) { [math]::Round([double]$s.PriceGross, 2) } else { '' }
    }
}
$rows | Export-Csv "$dataDir\kruitbosch_stok.csv" -NoTypeInformation -Encoding utf8

Write-Host "=== KRUITBOSCH 409 BISIKLET - durum dagilimi ==="
$rows | Group-Object durum | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize

# 2) Site eslesme analizi
$prodById = @{}; foreach ($p in $ap) { $prodById[$p.id] = $p }
$kbByCode = @{}; foreach ($r in $rows) { $kbByCode[$r.sku] = $r }

$matched = foreach ($v in $av) {
    $sku = "$($v.sku)".Trim()
    if ($sku -and $kbByCode.ContainsKey($sku)) {
        $k = $kbByCode[$sku]
        $siteDurum = switch ($v.stock_status) { 'instock' {'VAR'} 'onbackorder' {'ON_SIPARIS'} default {'YOK'} }
        $kbDurum = if ($k.stok -eq 1) { 'VAR' } else { 'YOK' }
        $parent = $prodById[$v.product_id]
        [PSCustomObject]@{
            product_id = $v.product_id; variation_id = $v.variation_id
            urun = $v.product_name; secenek = $v.attributes; sku = $sku
            site_durum = $siteDurum; kruitbosch_durum = $kbDurum
            kruitbosch_detay = $k.durum; gelis_tarihi = $k.gelis_tarihi
            degisim = if (($kbDurum -eq 'VAR' -and $siteDurum -ne 'VAR') -or ($kbDurum -eq 'YOK' -and $siteDurum -eq 'VAR')) { 'GUNCELLE' } else { '' }
            yeni_status = if ($kbDurum -eq 'VAR') { 'instock' } else { 'outofstock' }
        }
    }
}
$matched | Export-Csv "$dataDir\site_kruitbosch_eslesme.csv" -NoTypeInformation -Encoding utf8

Write-Host "=== SITE ESLESMESI: $(@($matched).Count) varyasyon ==="
Write-Host "--- site durumu x kruitbosch gercegi ---"
$matched | Group-Object site_durum, kruitbosch_durum | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
$upd = @($matched | Where-Object { $_.degisim -eq 'GUNCELLE' })
Write-Host "GUNCELLENMESI GEREKEN varyasyon: $($upd.Count)"
Write-Host "--- satis kaybi: sitede YOK/on-siparis ama Kruitbosch'ta VAR ---"
$lost = @($matched | Where-Object { $_.kruitbosch_durum -eq 'VAR' -and $_.site_durum -ne 'VAR' })
Write-Host "adet: $($lost.Count)"
$lost | Select-Object -First 12 urun, secenek, sku, site_durum, kruitbosch_detay | Format-Table -AutoSize
Write-Host "--- yanlis satis riski: sitede VAR ama Kruitbosch'ta YOK ---"
$ghost = @($matched | Where-Object { $_.kruitbosch_durum -eq 'YOK' -and $_.site_durum -eq 'VAR' })
Write-Host "adet: $($ghost.Count)"
$ghost | Select-Object -First 12 urun, secenek, sku, kruitbosch_detay, gelis_tarihi | Format-Table -AutoSize
