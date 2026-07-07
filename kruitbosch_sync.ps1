# Kruitbosch stok verisini zaandambicycle.nl'e senkronlar.
# Girdi: SKU -> stok eslemesi iceren bir CSV (Kruitbosch API'nizden export).
#   Beklenen kolonlar: sku, stok   (stok: sayi VEYA "var"/"yok" — ikisi de calisir)
#   Kolon adlari farkliysa -SkuColumn / -StockColumn ile belirtin.
#
# Kullanim:
#   On izleme:
#     .\kruitbosch_sync.ps1 -ConsumerKey ck_xxx -ConsumerSecret cs_xxx -KruitboschCsv kruitbosch_stok.csv
#   Uygula:
#     .\kruitbosch_sync.ps1 -ConsumerKey ck_xxx -ConsumerSecret cs_xxx -KruitboschCsv kruitbosch_stok.csv -Apply
#   Adet takibini de acmak icin (miktarlari da yazar):
#     ... -Apply -SetQuantities

param(
    [Parameter(Mandatory=$true)][string]$ConsumerKey,
    [Parameter(Mandatory=$true)][string]$ConsumerSecret,
    [Parameter(Mandatory=$true)][string]$KruitboschCsv,
    [string]$SkuColumn = 'sku',
    [string]$StockColumn = 'stok',
    [switch]$Apply,
    [switch]$SetQuantities
)

$base = "https://www.zaandambicycle.nl/wp-json/wc/v3"
$auth = "consumer_key=$ConsumerKey&consumer_secret=$ConsumerSecret"
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"

# 1) Kruitbosch verisi: SKU -> stok
$kb = Import-Csv $KruitboschCsv
$kbMap = @{}
foreach ($row in $kb) {
    $sku = "$($row.$SkuColumn)".Trim()
    if (-not $sku) { continue }
    $raw = "$($row.$StockColumn)".Trim().ToLower()
    $qty = 0
    if ($raw -match '^\d+$') { $qty = [int]$raw }
    elseif ($raw -in 'var','ja','yes','true','in stock','op voorraad') { $qty = 1 }
    $kbMap[$sku] = $qty
}
Write-Host "Kruitbosch verisi: $($kbMap.Count) SKU yuklendi."

# 2) Sitedeki varyasyonlar (variations.csv) ile eslestir
$vars = Import-Csv "$dataDir\variations.csv"
$matched = @(); $unmatched = @()
foreach ($v in $vars) {
    $sku = "$($v.sku)".Trim()
    if ($sku -and $kbMap.ContainsKey($sku)) {
        $qty = $kbMap[$sku]
        $matched += [PSCustomObject]@{
            product_id = $v.product_id; variation_id = $v.variation_id
            urun = $v.product_name; secenek = $v.attributes; sku = $sku
            site_durumu = if ($v.availability -match 'Uitverkocht') { 'YOK' } elseif ($v.availability -match 'nabestelling') { 'ON_SIPARIS' } elseif ($v.is_in_stock -eq 'True') { 'VAR' } else { 'YOK' }
            kruitbosch_adet = $qty
            yeni_durum = if ($qty -gt 0) { 'instock' } else { 'outofstock' }
        }
    } elseif ($sku) {
        $unmatched += $v
    }
}
$changes = @($matched | Where-Object {
    ($_.yeni_durum -eq 'instock' -and $_.site_durumu -ne 'VAR') -or
    ($_.yeni_durum -eq 'outofstock' -and $_.site_durumu -ne 'YOK')
})

Write-Host "Eslesen varyasyon: $($matched.Count) / $($vars.Count)  |  Kruitbosch'ta bulunamayan site SKU'su: $($unmatched.Count)"
Write-Host "Durumu DEGISECEK varyasyon: $($changes.Count)"
$matched | Export-Csv "$dataDir\kruitbosch_eslesme.csv" -NoTypeInformation -Encoding utf8
$unmatched | Select-Object product_id, product_name, sku, attributes | Export-Csv "$dataDir\kruitbosch_eslesmeyen.csv" -NoTypeInformation -Encoding utf8
$changes | Format-Table urun, secenek, sku, site_durumu, kruitbosch_adet, yeni_durum -AutoSize

if (-not $Apply) {
    Write-Host ""
    Write-Host ">>> ON IZLEME modu. Eslesme raporu: data\kruitbosch_eslesme.csv. Uygulamak icin -Apply." -ForegroundColor Yellow
    exit 0
}

# 3) WooCommerce'e yaz (varyasyon bazinda, urun basina batch)
$ok = 0; $fail = 0
$byProduct = $changes | Group-Object product_id
foreach ($g in $byProduct) {
    $updates = @($g.Group | ForEach-Object {
        $u = @{ id = [int]$_.variation_id; stock_status = $_.yeni_durum }
        if ($SetQuantities) { $u.manage_stock = $true; $u.stock_quantity = [int]$_.kruitbosch_adet }
        $u
    })
    try {
        $body = @{ update = $updates } | ConvertTo-Json -Depth 4
        $r = Invoke-RestMethod -Method Post -Uri "$base/products/$($g.Name)/variations/batch?$auth" -Body $body -ContentType 'application/json' -TimeoutSec 60
        $ok += $updates.Count
        Write-Host "[OK] urun $($g.Name): $($updates.Count) varyasyon guncellendi"
    } catch {
        $fail += $updates.Count
        Write-Host "[HATA] urun $($g.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 400
}
Write-Host ""
Write-Host "=== BITTI: $ok varyasyon guncellendi, $fail hata. ==="
Write-Host "Not: Woo, varyasyon degisince parent durumunu otomatik turetir; yine de kontrol icin build_report.ps1 + fetch_variations.ps1 tekrar calistirilabilir."
