# Shopify'a yuklenecek birlesik katalogu kurar: Kruitbosch 409 + Accell 454 kod
# Fiyat oncelik sirasi: 1) eski Woo sitesi fiyati  2) mevcut Shopify fiyati  3) tedarikci tavsiye fiyati
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"

$kbProducts = Get-Content "$dataDir\kruitbosch_products_raw.json" -Raw | ConvertFrom-Json
$kbStocks   = Get-Content "$dataDir\kruitbosch_stocks_raw.json" -Raw | ConvertFrom-Json
$acc        = Import-Csv "$dataDir\accentry_stok.csv"
$av         = Import-Csv "$dataDir\admin_variations.csv"
$ap         = Import-Csv "$dataDir\admin_products.csv"
$shopify    = Import-Csv "$dataDir\shopify_products.csv"

# --- fiyat kaynaklari ---
$wooPrice = @{}
foreach ($v in $av) { $s = "$($v.sku)".Trim(); if ($s -and $v.price -and [double]$v.price -gt 0 -and -not $wooPrice.ContainsKey($s)) { $wooPrice[$s] = [double]$v.price } }
foreach ($p in $ap) { $s = "$($p.sku)".Trim(); if ($s -and $p.price -and [double]$p.price -gt 0 -and -not $wooPrice.ContainsKey($s)) { $wooPrice[$s] = [double]$p.price } }
$shopPrice = @{}
foreach ($r in $shopify) { $s = "$($r.sku)".Trim(); if ($s -and $r.price -and [double]$r.price -gt 0 -and -not $shopPrice.ContainsKey($s)) { $shopPrice[$s] = [double]$r.price } }

$kbStockByCode = @{}
foreach ($s in $kbStocks) { $kbStockByCode["$($s.ProductCode)".Trim()] = $s }

function Resolve-Price($sku, $advies) {
    if ($wooPrice.ContainsKey($sku)) { return @{ p = $wooPrice[$sku]; src = 'woo' } }
    if ($shopPrice.ContainsKey($sku)) { return @{ p = $shopPrice[$sku]; src = 'shopify' } }
    if ($advies -and [double]$advies -gt 0) { return @{ p = [math]::Round([double]$advies, 2); src = 'advies' } }
    return @{ p = $null; src = 'YOK' }
}

$catalog = New-Object System.Collections.ArrayList

# --- Kruitbosch ---
foreach ($p in $kbProducts) {
    $code = "$($p.ProductCode)".Trim()
    if (-not $code) { continue }
    $s = $kbStockByCode[$code]
    $qty = 0
    if ($s) { switch ([int]$s.AvailabilityId) { 1 { $qty = 10 } 2 { $qty = 2 } default { $qty = 0 } } }
    $brand = ($p.Description -split ' ')[0]
    $pr = Resolve-Price $code $p.RecommendedSalesPrice
    [void]$catalog.Add([PSCustomObject]@{
        sku = $code; kaynak = 'kruitbosch'
        title = $p.Description; vendor = $brand
        body = $p.DescriptionLong
        barcode = $p.EANCode
        images = $p.Image
        qty = $qty
        durum_detay = if ($s) { $s.Availability } else { 'kayit yok' }
        price = $pr.p; price_kaynak = $pr.src
    })
}

# --- Accell ---
foreach ($a in $acc) {
    $code = "$($a.sku)".Trim()
    if (-not $code) { continue }
    $qty = 0
    if ([int]$a.stock -gt 0) { $qty = [int]$a.stock }
    elseif ([int]$a.stock_status -le 2) { $qty = 5 }
    $pr = Resolve-Price $code $a.retail_price
    [void]$catalog.Add([PSCustomObject]@{
        sku = $code; kaynak = 'accell'
        title = if ($a.description -and $a.caption) { "$($a.description) $($a.caption)".Trim() } elseif ($a.description) { $a.description } else { $a.caption }
        vendor = $a.brand
        body = ''
        barcode = ''
        images = $a.images
        qty = $qty
        durum_detay = "status $($a.stock_status)"
        price = $pr.p; price_kaynak = $pr.src
    })
}

$catalog | Export-Csv "$dataDir\shopify_katalog.csv" -NoTypeInformation -Encoding utf8

Write-Host "=== KATALOG: $($catalog.Count) kod ==="
Write-Host "--- kaynak ---"
$catalog | Group-Object kaynak | Format-Table Name, Count -AutoSize
Write-Host "--- fiyat kaynagi ---"
$catalog | Group-Object price_kaynak | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
Write-Host "--- fiyatsiz kalan ---"
@($catalog | Where-Object { -not $_.price }).Count
Write-Host "--- stokta (qty>0) ---"
@($catalog | Where-Object { [int]$_.qty -gt 0 }).Count
Write-Host "--- SKU cakismasi (iki kaynakta da olan) ---"
$dup = $catalog | Group-Object sku | Where-Object { $_.Count -gt 1 }
@($dup).Count
