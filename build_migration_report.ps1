# Shopify'a tasima analizi: hangi bisikletlerin canli stok verisi var?
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$final = Import-Csv "$dataDir\stok_listesi_final.csv"
$av    = Import-Csv "$dataDir\admin_variations.csv"
$kbCsv = Import-Csv "$dataDir\kruitbosch_stok.csv"

$kbCodes = @{}; foreach ($k in $kbCsv) { $kbCodes["$($k.sku)".Trim()] = $k }
$avByProduct = $av | Group-Object product_id -AsHashTable -AsString

$bikes = @($final | Where-Object { $_.bisiklet_mi -eq 'EVET' })

$rows = foreach ($b in $bikes) {
    $vars = $avByProduct["$($b.id)"]
    $skus = if ($vars) { @($vars | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ }) } else { @("$($b.sku_listesi)".Trim() | Where-Object { $_ }) }
    $matched = @($skus | Where-Object { $kbCodes.ContainsKey($_) })
    $kbStokVar = @($matched | Where-Object { $kbCodes[$_].stok -eq '1' })
    $durum = if ($skus.Count -eq 0) { 'SKU_YOK' }
             elseif ($matched.Count -eq $skus.Count) { 'TAM_VERI' }
             elseif ($matched.Count -gt 0) { 'KISMI_VERI' }
             else { 'VERI_YOK' }
    [PSCustomObject]@{
        id = $b.id; urun_adi = $b.urun_adi; marka = $b.marka; fiyat_eur = $b.fiyat_eur
        secenek = $skus.Count; kruitbosch_eslesen = $matched.Count
        stok_verisi = $durum
        kb_stokta_secenek = $kbStokVar.Count
        tasinacak_mi = if ($matched.Count -gt 0) { 'EVET' } else { 'SIMDILIK_HAYIR' }
        site_stok_durumu = $b.stok_durumu
    }
}
$rows | Sort-Object tasinacak_mi, marka, urun_adi | Export-Csv "$dataDir\shopify_tasima_listesi.csv" -NoTypeInformation -Encoding utf8

Write-Host "=== SITEDEKI 385 BISIKLET - STOK VERISI DURUMU ==="
$rows | Group-Object stok_verisi | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize

Write-Host "=== TASINACAK MI? ==="
$rows | Group-Object tasinacak_mi | Format-Table Name, Count -AutoSize

Write-Host "=== MARKA BAZINDA ==="
$rows | Group-Object marka | Sort-Object Count -Descending | ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{
        Marka = $_.Name; Toplam = $_.Count
        VeriVar = @($g | Where-Object { $_.tasinacak_mi -eq 'EVET' }).Count
        VeriYok = @($g | Where-Object { $_.tasinacak_mi -ne 'EVET' }).Count
    }
} | Format-Table -AutoSize

# Kruitbosch kataloginda olup sitede olmayan modeller
$siteSkus = @{}; foreach ($v in $av) { $s = "$($v.sku)".Trim(); if ($s) { $siteSkus[$s] = 1 } }
$newCodes = @($kbCsv | Where-Object { -not $siteSkus.ContainsKey("$($_.sku)".Trim()) })
$newInStock = @($newCodes | Where-Object { $_.stok -eq '1' })
Write-Host "=== KRUITBOSCH'TA OLUP SITEDE OLMAYAN ==="
Write-Host "kod: $($newCodes.Count) (stokta olan: $($newInStock.Count))"
$newInStock | Group-Object { ($_.urun -split ' ')[0] } | Sort-Object Count -Descending | Select-Object -First 8 | Format-Table Name, Count -AutoSize
