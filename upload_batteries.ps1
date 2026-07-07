# 1) 14 aku/sarj urununu Shopify'a yukler (idempotent)
# 2) Her bisikleti uyumlu akuleriyle baglar (complementary products metafield)
param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ClientSecret
)
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$locationId = 118973399427
$doneFile = "$dataDir\battery_done.txt"

$body = @{ grant_type = "client_credentials"; client_id = $ClientId; client_secret = $ClientSecret } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $body -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
Write-Host "token OK"

function Fix-Num($s) { if ($null -eq $s) { return $null }; return ([string]$s).Replace(',', '.') }

# Woo fiyatlari (aku SKU'lari eski sitede "Kies een accu" olarak vardi)
$av = Import-Csv "$dataDir\admin_variations.csv"
$wooPrice = @{}
foreach ($v in $av) { $s = "$($v.sku)".Trim(); if ($s -and $v.price -and [double](Fix-Num $v.price) -gt 0 -and -not $wooPrice.ContainsKey($s)) { $wooPrice[$s] = [double](Fix-Num $v.price) } }

# --- 1) Aku urunlerini yukle ---
$bats = Import-Csv "$dataDir\battery_catalog.csv"
$done = @{}; if (Test-Path $doneFile) { Get-Content $doneFile | ForEach-Object { $done[$_] = 1 } }
foreach ($b in $bats) {
    $sku = "$($b.sku)".Trim()
    if ($done.ContainsKey($sku)) { continue }
    $price = if ($wooPrice.ContainsKey($sku)) { $wooPrice[$sku] } else { [double](Fix-Num $b.retail_price) }
    $qty = 0
    if ([int]$b.stock -gt 0) { $qty = [int]$b.stock } elseif ([int]$b.stock_status -le 2) { $qty = 5 }
    $title = if ($b.description) { "$($b.description) - $($b.caption)".Trim(' -') } else { $b.caption }
    $imgs = @()
    if ($b.images) { $imgs = @(($b.images -split ' \| ') | Where-Object { $_ -match '^https?://' } | ForEach-Object { @{ src = $_ } }) }
    $product = @{
        title = $title
        vendor = if ($b.brand) { $b.brand } else { "Bosch" }
        status = if ($qty -gt 0) { "active" } else { "draft" }
        tags = "Accu, aku"
        variants = @(@{ sku = $sku; price = ("{0:0.00}" -f $price).Replace(',', '.'); inventory_management = "shopify"; inventory_policy = "deny" })
    }
    if ($imgs.Count) { $product.images = $imgs }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body (@{ product = $product } | ConvertTo-Json -Depth 6) -ContentType 'application/json' -TimeoutSec 60
        Add-Content $doneFile $sku
        Start-Sleep -Milliseconds 300
        try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/inventory_levels/set.json" -Headers $h -Body (@{ location_id = $locationId; inventory_item_id = $resp.product.variants[0].inventory_item_id; available = $qty } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60 } catch { Write-Host "[stok HATA] $sku" }
        Write-Host "[OK] aku $sku - $title (qty $qty, EUR $price)"
    } catch { Write-Host "[HATA] $sku : $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 400
}

# --- 2) SKU -> product_id haritasi (tum magaza) ---
$skuMap = @{}
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            foreach ($v in $p.variants) { $s = "$($v.sku)".Trim(); if ($s -and -not $skuMap.ContainsKey($s)) { $skuMap[$s] = $p.id } }
        }
        $url = $null
        if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 500
    }
}
Write-Host "magaza SKU haritasi: $($skuMap.Count)"

# --- 3) Bisiklet -> aku baglantilari (complementary products metafield) ---
$links = Import-Csv "$dataDir\bike_battery_links.csv"
$byBike = $links | Group-Object bike_sku
$ok = 0; $skip = 0; $fail = 0
foreach ($g in $byBike) {
    $bikeId = $skuMap["$($g.Name)".Trim()]
    if (-not $bikeId) { $skip++; continue }
    $gids = @($g.Group | ForEach-Object { $skuMap["$($_.item_sku)".Trim()] } | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { "gid://shopify/Product/$_" })
    if (-not $gids.Count) { $skip++; continue }
    $mf = @{ metafield = @{ namespace = "shopify--discovery--product_recommendation"; key = "complementary_products"; type = "list.product_reference"; value = ($gids | ConvertTo-Json -Compress) } }
    if ($gids.Count -eq 1) { $mf.metafield.value = "[" + ($gids[0] | ConvertTo-Json) + "]" }
    try {
        $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products/$bikeId/metafields.json" -Headers $h -Body ($mf | ConvertTo-Json -Depth 5) -ContentType 'application/json' -TimeoutSec 60
        $ok++
    } catch { $fail++ }
    if ((($ok + $fail) % 25) -eq 0) { Write-Host "baglanti: ok $ok / fail $fail / skip $skip" }
    Start-Sleep -Milliseconds 400
}
Write-Host "DONE. baglanan bisiklet: $ok | atlanan: $skip | hata: $fail"
