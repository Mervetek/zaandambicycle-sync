# SALT OKUNUR KESIF: eski site Cortina e-bike sayfalarindaki gomulu aku/lader secicilerini cikarir
# Cikti: data\cortina_battery_map.csv (bisiklet SKU -> aku/lader SKU listesi) + platform ozeti
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"

# eski sitedeki Cortina e-bike urunleri
$all = @()
for ($page = 1; $page -le 6; $page++) {
    $r = Invoke-RestMethod "$wooBase/products?per_page=100&page=$page&status=publish&$wooAuth" -TimeoutSec 60
    if (-not $r) { break }
    $all += $r
    if ($r.Count -lt 100) { break }
    Start-Sleep -Milliseconds 250
}
$cortinaE = @($all | Where-Object { ($_.categories | ForEach-Object { $_.name }) -match 'Cortina' -and $_.name -match 'E-' })
Write-Host "eski site Cortina e-bike: $($cortinaE.Count)"

# secici urunlerin varyasyon SKU'lari (id -> sku listesi)
$choosers = Invoke-RestMethod "$wooBase/products?per_page=100&search=Kies een&status=publish&$wooAuth" -TimeoutSec 60
$chooserSkus = @{}
foreach ($c in $choosers) {
    $vs = Invoke-RestMethod "$wooBase/products/$($c.id)/variations?per_page=50&$wooAuth" -TimeoutSec 30
    $chooserSkus["$($c.id)"] = @{ name = $c.name; skus = @($vs | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ }) }
    Start-Sleep -Milliseconds 200
}
Write-Host "secici: $($chooserSkus.Count)"

# her bisiklet sayfasindan gomulu form id'lerini oku
$rows = @()
$i = 0
foreach ($p in $cortinaE) {
    $i++
    try {
        $html = (Invoke-WebRequest -Uri $p.permalink -UseBasicParsing -TimeoutSec 30).Content
        $ids = @([regex]::Matches($html, 'data-product_id="(\d+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Where-Object { $_ -ne "$($p.id)" })
        # bisikletin kendi varyasyon SKU'lari
        $vs = Invoke-RestMethod "$wooBase/products/$($p.id)/variations?per_page=50&$wooAuth" -TimeoutSec 30
        $bikeSkus = @($vs | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ })
        foreach ($cid in $ids) {
            if ($chooserSkus.ContainsKey($cid)) {
                $c = $chooserSkus[$cid]
                $tur = if ($c.name -match 'lader') { 'lader' } else { 'accu' }
                foreach ($bs in $bikeSkus) {
                    $rows += [PSCustomObject]@{ bike_sku = $bs; bike_name = $p.name; tur = $tur; item_skus = ($c.skus -join '|') }
                }
            }
        }
    } catch { }
    if ($i % 15 -eq 0) { Write-Host "$i / $($cortinaE.Count)" }
    Start-Sleep -Milliseconds 300
}
$rows | Export-Csv "$dataDir\cortina_battery_map.csv" -NoTypeInformation -Encoding utf8
Write-Host "eslesme satiri: $($rows.Count)"
Write-Host "--- ozet: aku setleri ---"
$rows | Where-Object { $_.tur -eq 'accu' } | Group-Object item_skus | Sort-Object Count -Descending | ForEach-Object { "{0,4}x  {1}" -f $_.Count, $_.Name }
Write-Host "--- ozet: lader setleri ---"
$rows | Where-Object { $_.tur -eq 'lader' } | Group-Object item_skus | Sort-Object Count -Descending | ForEach-Object { "{0,4}x  {1}" -f $_.Count, $_.Name }
