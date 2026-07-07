$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$all = Get-Content "$dataDir\products_raw.json" -Raw | ConvertFrom-Json
$vars = Import-Csv "$dataDir\variations.csv"
$varsByProduct = $vars | Group-Object product_id -AsHashTable -AsString

$brandNames = 'Cortina','Batavus','Sparta','QWIC','Alpina','Raleigh','Loekie','UGO'
$bikeCatPattern = 'E-Bikes|Stads|toerfietsen|Kinderfietsen|Vouwfietsen|Raleigh|UGO|Loekie|Elektrische'

$rows = foreach ($p in $all) {
    $cats = @($p.categories | ForEach-Object { $_.name })
    $catStr = $cats -join ' | '
    $brand = ($brandNames | Where-Object { $catStr -match $_ } | Select-Object -First 1)
    if (-not $brand) { $brand = 'Diger' }
    $isBike = ($catStr -match $bikeCatPattern) -and ($catStr -notmatch 'Batterijen|Onderdelen')

    $pv = $null
    if ($varsByProduct) { $pv = $varsByProduct["$($p.id)"] }

    if ($pv) {
        $inStock   = @($pv | Where-Object { $_.is_in_stock -eq 'True' -and $_.availability -notmatch 'nabestelling' })
        $backorder = @($pv | Where-Object { $_.availability -match 'nabestelling' })
        $total = $pv.Count
        if ($inStock.Count -gt 0) { $status = 'VAR' }
        elseif ($backorder.Count -gt 0) { $status = 'ON_SIPARIS' }
        else { $status = 'YOK' }
        $sizesIn = ($inStock | ForEach-Object { $_.attributes }) -join ', '
        $skus = ($pv | ForEach-Object { $_.sku } | Where-Object { $_ } | Select-Object -Unique) -join ', '
    } else {
        $total = 1
        if ($p.is_on_backorder) { $status = 'ON_SIPARIS'; $inC = 0; $backC = 1 }
        elseif ($p.is_in_stock) { $status = 'VAR' } else { $status = 'YOK' }
        $inStock = if ($status -eq 'VAR') { @(1) } else { @() }
        $backorder = if ($status -eq 'ON_SIPARIS') { @(1) } else { @() }
        $sizesIn = ''
        $skus = $p.sku
    }

    # site parent status for consistency check
    $siteStatus = if ($p.is_on_backorder) { 'ON_SIPARIS' } elseif ($p.is_in_stock) { 'VAR' } else { 'YOK' }

    [PSCustomObject]@{
        id             = $p.id
        urun_adi       = $p.name
        marka          = $brand
        bisiklet_mi    = if ($isBike) { 'EVET' } else { 'HAYIR' }
        kategoriler    = $catStr
        sku_listesi    = $skus
        fiyat_eur      = [math]::Round([double]$p.prices.price / 100, 2)
        stok_durumu    = $status
        toplam_secenek = $total
        stokta_secenek = $inStock.Count
        onsiparis_secenek = $backorder.Count
        stokta_bedenler = $sizesIn
        site_gosterimi = $siteStatus
        tutarsizlik    = if ($siteStatus -ne $status) { 'EVET' } else { '' }
        url            = $p.permalink
    }
}

$rows | Sort-Object marka, urun_adi | Export-Csv "$dataDir\stok_listesi.csv" -NoTypeInformation -Encoding utf8

Write-Host "=== GENEL (434 urun) ==="
$rows | Group-Object stok_durumu | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize

Write-Host "=== SADECE BISIKLETLER ==="
$bikes = $rows | Where-Object { $_.bisiklet_mi -eq 'EVET' }
Write-Host "Bisiklet sayisi: $($bikes.Count)"
$bikes | Group-Object stok_durumu | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize

Write-Host "=== MARKA x DURUM (bisikletler) ==="
$bikes | Group-Object marka | Sort-Object Count -Descending | ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{
        Marka = $_.Name; Toplam = $_.Count
        VAR = @($g | Where-Object { $_.stok_durumu -eq 'VAR' }).Count
        YOK = @($g | Where-Object { $_.stok_durumu -eq 'YOK' }).Count
        ON_SIPARIS = @($g | Where-Object { $_.stok_durumu -eq 'ON_SIPARIS' }).Count
    }
} | Format-Table -AutoSize

Write-Host "=== TUTARSIZLIK: site gosterimi != varyasyon gercegi ==="
$mismatch = $rows | Where-Object { $_.tutarsizlik -eq 'EVET' }
Write-Host "Tutarsiz urun: $($mismatch.Count)"
$mismatch | Group-Object site_gosterimi, stok_durumu | Format-Table Name, Count -AutoSize
$mismatch | Select-Object -First 15 urun_adi, marka, site_gosterimi, stok_durumu, stokta_bedenler | Format-Table -AutoSize

Write-Host "=== VAR ama sadece 1-2 beden stokta (kismi stok) ==="
$partial = $bikes | Where-Object { $_.stok_durumu -eq 'VAR' -and [int]$_.toplam_secenek -gt 1 -and [int]$_.stokta_secenek -lt [int]$_.toplam_secenek }
Write-Host "Kismi stoklu bisiklet: $($partial.Count)"
