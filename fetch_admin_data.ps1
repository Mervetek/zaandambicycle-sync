param(
    [Parameter(Mandatory=$true)][string]$ConsumerKey,
    [Parameter(Mandatory=$true)][string]$ConsumerSecret
)
$base = "https://www.zaandambicycle.nl/wp-json/wc/v3"
$auth = "consumer_key=$ConsumerKey&consumer_secret=$ConsumerSecret"
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"

# 1) Tum urunler (admin verisi)
$products = @()
for ($page = 1; $page -le 10; $page++) {
    $r = Invoke-RestMethod "$base/products?per_page=100&page=$page&status=publish&$auth" -TimeoutSec 60
    if (-not $r) { break }
    $products += $r
    Write-Host "urun sayfa $page -> $($r.Count) (toplam $($products.Count))"
    if ($r.Count -lt 100) { break }
    Start-Sleep -Milliseconds 300
}

$prodRows = $products | ForEach-Object {
    [PSCustomObject]@{
        id = $_.id; name = $_.name; sku = $_.sku; type = $_.type; status = $_.status
        catalog_visibility = $_.catalog_visibility
        categories = (@($_.categories | ForEach-Object { $_.name }) -join ' | ')
        price = $_.price; regular_price = $_.regular_price
        stock_status = $_.stock_status; manage_stock = $_.manage_stock; stock_quantity = $_.stock_quantity
        backorders = $_.backorders
        variation_ids = ($_.variations -join ',')
        total_sales = $_.total_sales
        date_modified = $_.date_modified
        permalink = $_.permalink
    }
}
$prodRows | Export-Csv "$dataDir\admin_products.csv" -NoTypeInformation -Encoding utf8
Write-Host "Urunler kaydedildi: $($prodRows.Count)"

# 2) Varyasyonlar (variable urunler icin)
$varRows = New-Object System.Collections.ArrayList
$variable = @($products | Where-Object { $_.type -eq 'variable' })
$i = 0
foreach ($p in $variable) {
    $i++
    try {
        $vs = Invoke-RestMethod "$base/products/$($p.id)/variations?per_page=100&$auth" -TimeoutSec 60
        foreach ($v in $vs) {
            $attrs = (@($v.attributes | ForEach-Object { $_.option }) -join ' / ')
            [void]$varRows.Add([PSCustomObject]@{
                product_id = $p.id; product_name = $p.name
                variation_id = $v.id; sku = $v.sku; attributes = $attrs
                status = $v.status; purchasable = $v.purchasable
                stock_status = $v.stock_status; manage_stock = $v.manage_stock; stock_quantity = $v.stock_quantity
                backorders = $v.backorders
                price = $v.price
            })
        }
    } catch {
        Write-Host "[HATA] urun $($p.id): $($_.Exception.Message)"
    }
    if ($i % 25 -eq 0) { Write-Host "$i / $($variable.Count) urun, varyasyon: $($varRows.Count)" }
    Start-Sleep -Milliseconds 250
}
$varRows | Export-Csv "$dataDir\admin_variations.csv" -NoTypeInformation -Encoding utf8
Write-Host "DONE. urun: $($prodRows.Count), varyasyon: $($varRows.Count)"
