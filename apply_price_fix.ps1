# Advies ustunde satilan birimlerin fiyatini adviesprijs'e indirir (sadece fark > +1 EUR olanlar)
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"

$rows = Import-Csv "$dataDir\fiyat_karsilastirma.csv" | Where-Object { $_.urun -notmatch '^Kies een' -and [double]$_.fark -gt 1 }
$bySku = @{}
foreach ($r in $rows) { $bySku["$($r.sku)".Trim()] = [double](("$($r.advies)").Replace(',', '.')) }
Write-Host "indirilecek benzersiz SKU: $($bySku.Count)"

$av = Import-Csv "$dataDir\admin_variations.csv"
$ap = Import-Csv "$dataDir\admin_products.csv"

$ok = 0; $fail = 0
# varyasyonlar: urun basina batch
$targets = @($av | Where-Object { $bySku.ContainsKey("$($_.sku)".Trim()) })
Write-Host "varyasyon hedefi: $($targets.Count)"
$targets | Group-Object product_id | ForEach-Object {
    $upd = @($_.Group | ForEach-Object { @{ id = [int]$_.variation_id; regular_price = ("{0:0.00}" -f $bySku["$($_.sku)".Trim()]).Replace(',', '.') } })
    try {
        $null = Invoke-RestMethod -Method Post -Uri "$wooBase/products/$($_.Name)/variations/batch?$wooAuth" -Body (@{ update = $upd } | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 60
        $ok += $upd.Count
        $_.Group | ForEach-Object { Write-Host "[OK] $($_.product_name) [$($_.sku)] -> EUR $($bySku[$_.sku.Trim()])" }
    } catch { $fail += $upd.Count; Write-Host "[HATA] urun $($_.Name): $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 350
}
# basit urunler
foreach ($p in @($ap | Where-Object { $_.sku -and $bySku.ContainsKey("$($_.sku)".Trim()) -and $_.type -ne 'variable' })) {
    try {
        $np = ("{0:0.00}" -f $bySku["$($p.sku)".Trim()]).Replace(',', '.')
        $null = Invoke-RestMethod -Method Put -Uri "$wooBase/products/$($p.id)?$wooAuth" -Body (@{ regular_price = $np } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
        $ok++
        Write-Host "[OK] $($p.name) [$($p.sku)] -> EUR $np"
    } catch { $fail++ }
    Start-Sleep -Milliseconds 350
}
Write-Host "DONE. guncellenen: $ok | hata: $fail"
