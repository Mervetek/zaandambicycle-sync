# Shopify magazasindaki tum urunleri ceker (REST, sayfalama ile)
param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ClientSecret
)
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"
$api = "2024-10"

$body = @{ grant_type = "client_credentials"; client_id = $ClientId; client_secret = $ClientSecret } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $body -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
Write-Host "token OK"

$rows = New-Object System.Collections.ArrayList
$url = "https://$shop/admin/api/$api/products.json?limit=250&fields=id,title,vendor,status,created_at,updated_at,tags,variants"
$page = 0
while ($url) {
    $page++
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    $data = ($resp.Content | ConvertFrom-Json).products
    foreach ($p in $data) {
        foreach ($v in $p.variants) {
            [void]$rows.Add([PSCustomObject]@{
                product_id = $p.id; title = $p.title; vendor = $p.vendor; status = $p.status
                created_at = $p.created_at
                variant_id = $v.id; sku = $v.sku; barcode = $v.barcode
                price = $v.price; compare_at_price = $v.compare_at_price
                inventory_item_id = $v.inventory_item_id
                inventory_management = $v.inventory_management
                inventory_quantity = $v.inventory_quantity
                option1 = $v.option1
            })
        }
    }
    # Link header'dan sonraki sayfa
    $url = $null
    $link = $resp.Headers['Link']
    if ($link -and $link -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Write-Host "sayfa $page -> toplam varyant: $($rows.Count)"
    Start-Sleep -Milliseconds 600
}
$rows | Export-Csv "$dataDir\shopify_products.csv" -NoTypeInformation -Encoding utf8
Write-Host "DONE. $($rows.Count) varyant kaydedildi."

Write-Host "--- SKU mukerrerligi ---"
$dup = $rows | Where-Object { $_.sku } | Group-Object sku | Where-Object { $_.Count -gt 1 } | Sort-Object Count -Descending
Write-Host "mukerrer SKU sayisi: $(@($dup).Count)"
$dup | Select-Object -First 8 | Format-Table Name, Count -AutoSize

Write-Host "--- tedarikci verisiyle ortusme ---"
$kb = Import-Csv "$dataDir\kruitbosch_stok.csv"
$acc = Import-Csv "$dataDir\accentry_stok.csv"
$kbSet = @{}; foreach ($k in $kb) { $kbSet["$($k.sku)".Trim()] = 1 }
$accSet = @{}; foreach ($a in $acc) { $accSet["$($a.sku)".Trim()] = 1 }
$shopSkus = @($rows | Where-Object { $_.sku } | ForEach-Object { "$($_.sku)".Trim() } | Select-Object -Unique)
"shopify benzersiz SKU: $($shopSkus.Count)"
"kruitbosch ile eslesen: $(@($shopSkus | Where-Object { $kbSet.ContainsKey($_) }).Count)"
"accell ile eslesen: $(@($shopSkus | Where-Object { $accSet.ContainsKey($_) }).Count)"
