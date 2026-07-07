# Accentry verisini urun seviyesine toparla + Shopify tasima tablosunu guncelle
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$acc = Import-Csv "$dataDir\accentry_stok.csv"
$ap  = Import-Csv "$dataDir\admin_products.csv"
$av  = Import-Csv "$dataDir\admin_variations.csv"
$final = Import-Csv "$dataDir\stok_listesi_final.csv"

$accBySku = @{}; foreach ($a in $acc) { $accBySku["$($a.sku)".Trim()] = $a }
$avByProduct = $av | Group-Object product_id -AsHashTable -AsString

# stock_status yorumu: 1-2 = stokta, 3 = tarihli beklemede, 4+ = temin yok/belirsiz
function Get-AccStatus($a) {
    if ([int]$a.stock -gt 0 -or [int]$a.stock_status -le 2) { return 'VAR' }
    if ([int]$a.stock_status -eq 3) { return 'BEKLEMEDE' }
    return 'YOK'
}

$bikes = @($final | Where-Object { $_.bisiklet_mi -eq 'EVET' -and $_.marka -in 'Batavus','Sparta','Loekie' })
$rows = foreach ($b in $bikes) {
    $vars = $avByProduct["$($b.id)"]
    $skus = if ($vars) { @($vars | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ }) } else { @("$($b.sku_listesi)".Trim() | Where-Object { $_ }) }
    $found = @($skus | Where-Object { $accBySku.ContainsKey($_) })
    $statuses = @($found | ForEach-Object { Get-AccStatus $accBySku[$_] })
    $varCnt  = @($statuses | Where-Object { $_ -eq 'VAR' }).Count
    $bekCnt  = @($statuses | Where-Object { $_ -eq 'BEKLEMEDE' }).Count
    $genel = if ($varCnt -gt 0) { 'VAR' } elseif ($bekCnt -gt 0) { 'BEKLEMEDE' } else { 'YOK' }
    [PSCustomObject]@{
        id = $b.id; urun_adi = $b.urun_adi; marka = $b.marka
        secenek = $skus.Count; accell_bulunan = $found.Count
        accell_durum = $genel; stokta_secenek = $varCnt; beklemede_secenek = $bekCnt
        site_durum = $b.stok_durumu
        veri_var = if ($found.Count -gt 0) { 'EVET' } else { 'HAYIR' }
    }
}
$rows | Export-Csv "$dataDir\accentry_urun_analizi.csv" -NoTypeInformation -Encoding utf8

Write-Host "=== ACCELL MARKALI SITE BISIKLETLERI: $(@($rows).Count) ==="
Write-Host "--- stok verisi olan ---"
$rows | Group-Object veri_var | Format-Table Name, Count -AutoSize
Write-Host "--- Accell gercek durumu (urun seviyesi) ---"
$rows | Group-Object accell_durum | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
Write-Host "--- marka bazinda ---"
$rows | Group-Object marka | ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{ Marka = $_.Name; Toplam = $_.Count
        VAR = @($g | Where-Object { $_.accell_durum -eq 'VAR' }).Count
        BEKLEMEDE = @($g | Where-Object { $_.accell_durum -eq 'BEKLEMEDE' }).Count
        YOK = @($g | Where-Object { $_.accell_durum -eq 'YOK' }).Count }
} | Format-Table -AutoSize
Write-Host "--- site VAR diyor ama Accell YOK diyor (hayalet) ---"
$ghost = @($rows | Where-Object { $_.site_durum -eq 'VAR' -and $_.accell_durum -eq 'YOK' })
Write-Host "adet: $($ghost.Count)"
$ghost | Select-Object -First 10 urun_adi, marka, site_durum, accell_durum | Format-Table -AutoSize
Write-Host "--- site YOK diyor ama Accell VAR diyor (satis kaybi) ---"
$lost = @($rows | Where-Object { $_.site_durum -ne 'VAR' -and $_.accell_durum -eq 'VAR' })
Write-Host "adet: $($lost.Count)"
