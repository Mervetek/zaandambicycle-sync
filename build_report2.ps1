# Admin API verisinden nihai stok analizi
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$ap = Import-Csv "$dataDir\admin_products.csv"
$av = Import-Csv "$dataDir\admin_variations.csv"
$storefront = Import-Csv "$dataDir\products_full.csv"   # ilk vitrin (Store API) cekimi - musterinin gordugu
$sfById = $storefront | Group-Object id -AsHashTable -AsString
$avByProduct = $av | Group-Object product_id -AsHashTable -AsString

$brandNames = 'Cortina','Batavus','Sparta','QWIC','Alpina','Raleigh','Loekie','UGO'
$bikeCatPattern = 'E-Bikes|Stads|toerfietsen|Kinderfietsen|Vouwfietsen|Raleigh|UGO|Loekie|Elektrische'

function Get-DerivedStatus($children) {
    # WooCommerce kurali: herhangi bir cocuk instock -> instock; degilse onbackorder varsa -> onbackorder; yoksa outofstock
    if (@($children | Where-Object { $_.stock_status -eq 'instock' }).Count -gt 0) { return 'instock' }
    if (@($children | Where-Object { $_.stock_status -eq 'onbackorder' }).Count -gt 0) { return 'onbackorder' }
    return 'outofstock'
}

$rows = foreach ($p in $ap) {
    $brand = ($brandNames | Where-Object { $p.categories -match $_ } | Select-Object -First 1)
    if (-not $brand) { $brand = 'Diger' }
    $isHelper = $p.name -match '^Kies een accu'
    $isBike = (-not $isHelper) -and ($p.categories -match $bikeCatPattern) -and ($p.categories -notmatch 'Batterijen|Onderdelen')

    $children = $avByProduct["$($p.id)"]
    if ($children) {
        $derived = Get-DerivedStatus $children
        $inCnt   = @($children | Where-Object { $_.stock_status -eq 'instock' }).Count
        $backCnt = @($children | Where-Object { $_.stock_status -eq 'onbackorder' }).Count
        $outCnt  = @($children | Where-Object { $_.stock_status -eq 'outofstock' }).Count
        $totCnt  = @($children).Count
        $inSizes = (@($children | Where-Object { $_.stock_status -eq 'instock' } | ForEach-Object { $_.attributes })) -join ', '
        $skus    = (@($children | ForEach-Object { $_.sku } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
    } else {
        $derived = $p.stock_status
        $inCnt = 0; $backCnt = 0; $outCnt = 0; $totCnt = 0
        $inSizes = ''; $skus = $p.sku
    }

    # Musterinin listede gordugu (ilk Store API cekimi)
    $sf = $sfById["$($p.id)"]
    $sfStatus = if ($sf) {
        if ($sf.is_on_backorder -eq 'True') { 'onbackorder' } elseif ($sf.is_in_stock -eq 'True') { 'instock' } else { 'outofstock' }
    } else { '' }

    $trStatus = switch ($derived) { 'instock' { 'VAR' } 'onbackorder' { 'ON_SIPARIS' } default { 'YOK' } }

    [PSCustomObject]@{
        id = $p.id; urun_adi = $p.name; marka = $brand
        bisiklet_mi = if ($isBike) { 'EVET' } elseif ($isHelper) { 'AKU_SECICI' } else { 'HAYIR' }
        fiyat_eur = $p.price
        stok_durumu = $trStatus
        parent_status = $p.stock_status
        turetilmis_status = $derived
        parent_tutarsiz = if ($children -and $p.stock_status -ne $derived) { 'EVET' } else { '' }
        vitrin_status = $sfStatus
        vitrin_tutarsiz = if ($sfStatus -and $sfStatus -ne $derived) { 'EVET' } else { '' }
        toplam_secenek = $totCnt; stokta = $inCnt; on_siparis = $backCnt; tukendi = $outCnt
        stokta_bedenler = $inSizes
        sku_listesi = $skus
        toplam_satis = $p.total_sales
        url = $p.permalink
    }
}

$rows | Sort-Object marka, urun_adi | Export-Csv "$dataDir\stok_listesi_final.csv" -NoTypeInformation -Encoding utf8

$bikes = @($rows | Where-Object { $_.bisiklet_mi -eq 'EVET' })
Write-Host "=== NIHAI (admin verisi) - $($bikes.Count) bisiklet ==="
$bikes | Group-Object stok_durumu | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize

Write-Host "=== MARKA x DURUM ==="
$bikes | Group-Object marka | Sort-Object Count -Descending | ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{ Marka=$_.Name; Toplam=$_.Count
        VAR=@($g|Where-Object{$_.stok_durumu -eq 'VAR'}).Count
        YOK=@($g|Where-Object{$_.stok_durumu -eq 'YOK'}).Count
        ON_SIPARIS=@($g|Where-Object{$_.stok_durumu -eq 'ON_SIPARIS'}).Count }
} | Format-Table -AutoSize

Write-Host "=== PARENT tutarsiz (DB icinde parent != varyasyonlardan turetilen) ==="
$pmis = @($rows | Where-Object { $_.parent_tutarsiz -eq 'EVET' })
Write-Host "adet: $($pmis.Count)"
$pmis | Group-Object parent_status, turetilmis_status | Format-Table Name, Count -AutoSize
$pmis | Select-Object -First 12 id, urun_adi, marka, parent_status, turetilmis_status, stokta_bedenler | Format-Table -AutoSize

Write-Host "=== VITRIN tutarsiz (musterinin gordugu != admin gercegi) ==="
$vmis = @($rows | Where-Object { $_.vitrin_tutarsiz -eq 'EVET' -and $_.bisiklet_mi -ne 'AKU_SECICI' })
Write-Host "adet: $($vmis.Count)"
$vmis | Group-Object vitrin_status, turetilmis_status | Format-Table Name, Count -AutoSize
