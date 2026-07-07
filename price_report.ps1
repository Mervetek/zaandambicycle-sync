# Site fiyatlari vs tedarikci tavsiye fiyati (adviesprijs) karsilastirmasi (offline veri)
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$kbProducts = Get-Content "$dataDir\kruitbosch_products_raw.json" -Raw | ConvertFrom-Json
$acc = Import-Csv "$dataDir\accentry_stok.csv"
$bats = Import-Csv "$dataDir\battery_catalog.csv"
$kbStocks = Get-Content "$dataDir\kruitbosch_stocks_raw.json" -Raw | ConvertFrom-Json
$av = Import-Csv "$dataDir\admin_variations.csv"
$ap = Import-Csv "$dataDir\admin_products.csv"

function N($s) { if ($null -eq $s -or "$s" -eq '') { return $null }; return [double](("$s").Replace(',', '.')) }

# tavsiye fiyat haritasi
$advies = @{}
foreach ($p in $kbProducts) { $c = "$($p.ProductCode)".Trim(); $rp = N $p.RecommendedSalesPrice; if ($c -and $rp -gt 0) { $advies[$c] = $rp } }
foreach ($a in $acc) { $c = "$($a.sku)".Trim(); $rp = N $a.retail_price; if ($c -and $rp -gt 0 -and -not $advies.ContainsKey($c)) { $advies[$c] = $rp } }
foreach ($b in $bats) { $c = "$($b.sku)".Trim(); $rp = N $b.retail_price; if ($c -and $rp -gt 0 -and -not $advies.ContainsKey($c)) { $advies[$c] = $rp } }
# alis fiyati haritasi (zarar kontrolu)
$alis = @{}
foreach ($s in $kbStocks) { $c = "$($s.ProductCode)".Trim(); $pn = N $s.PriceNett; if ($c -and $pn -gt 0) { $alis[$c] = $pn } }

# site fiyatlari (urun adiyla)
$prodName = @{}; foreach ($p in $ap) { $prodName[$p.id] = $p.name }
$site = @()
foreach ($v in $av) { $s = "$($v.sku)".Trim(); if ($s) { $site += [PSCustomObject]@{ sku = $s; fiyat = N $v.price; urun = $prodName[$v.product_id]; secenek = $v.attributes } } }
foreach ($p in $ap) { $s = "$($p.sku)".Trim(); if ($s) { $site += [PSCustomObject]@{ sku = $s; fiyat = N $p.price; urun = $p.name; secenek = '' } } }

$rows = @()
foreach ($x in $site) {
    if (-not $advies.ContainsKey($x.sku) -or $null -eq $x.fiyat) { continue }
    $adv = $advies[$x.sku]
    $fark = [math]::Round($x.fiyat - $adv, 2)
    $al = if ($alis.ContainsKey($x.sku)) { $alis[$x.sku] } else { $null }
    $rows += [PSCustomObject]@{
        urun = $x.urun; secenek = $x.secenek; sku = $x.sku
        site_fiyat = $x.fiyat; advies = $adv; fark = $fark
        fark_yuzde = if ($adv -gt 0) { [math]::Round(100 * $fark / $adv, 1) } else { $null }
        alis_net = $al
        zarar_riski = if ($al -and $x.fiyat -lt $al) { 'EVET' } else { '' }
    }
}
$rows | Sort-Object fark | Export-Csv "$dataDir\fiyat_karsilastirma.csv" -NoTypeInformation -Encoding utf8

$diff = @($rows | Where-Object { [math]::Abs($_.fark) -gt 1 })
Write-Host "karsilastirilan birim: $($rows.Count)"
Write-Host "advies ile AYNI (+-1 EUR): $($rows.Count - $diff.Count)"
Write-Host "FARKLI: $($diff.Count)"
Write-Host "  site DAHA UCUZ: $(@($diff | Where-Object { $_.fark -lt 0 }).Count)"
Write-Host "  site DAHA PAHALI: $(@($diff | Where-Object { $_.fark -gt 0 }).Count)"
Write-Host "  ZARAR RISKI (satis < bayi alisi): $(@($rows | Where-Object { $_.zarar_riski -eq 'EVET' }).Count)"
Write-Host ""
Write-Host "--- en buyuk sapmalar ---"
$diff | Sort-Object { [math]::Abs($_.fark) } -Descending | Select-Object -First 15 urun, secenek, sku, site_fiyat, advies, fark | Format-Table -AutoSize
