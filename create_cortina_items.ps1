# Cortina aku/lader C-kod urunlerini Shopify'da olusturur (idempotent: SKU varsa atlar)
# Fiyat = Kruitbosch advies; stok = AvailabilityId (1->10, 2->2, diger->0); gorsel = Kruitbosch CDN
# Politika: fiyatli her urun aktif (stoksuz da vitrinde, qty=0)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference = 'Continue'
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $loc = 118973399427
$kUser = $env:KRUITBOSCH_USERNAME; $kPass = $env:KRUITBOSCH_PASSWORD
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${kUser}:${kPass}"))
$kh = @{ Authorization = "Basic $pair" }

$ccodes = @((Import-Csv "$dataDir\kruitbosch_ccode_katalog.csv").code)
Write-Host "hedef C-kod: $($ccodes.Count)"

# --- Kruitbosch katalog (Image dahil) ---
$kp = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=false&ExcludeBlocked=false&IncludeAttributes=false&IncludeAdditionalImages=false&IncludeOriginalImages=false&IncludeInActive=true" -Headers $kh -TimeoutSec 300
$kat = @{}
foreach ($p in @($kp.Products)) {
    $c = "$($p.ProductCode)".Trim()
    if ($c -in $ccodes) { $kat[$c] = $p }
}
Write-Host "katalog: $($kat.Count)/$($ccodes.Count)"

# --- stok ---
$stok = @{}
$r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$kUser&Products=$($ccodes -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 120
foreach ($s in @($r.StocksAndPrices)) { $stok["$($s.ProductCode)".Trim()] = [int]$s.AvailabilityId }
Write-Host "stok kaydi: $($stok.Count)"

# --- Shopify ---
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

$made = 0; $skip = 0; $fail = 0
foreach ($c in $ccodes) {
    # idempotentlik: SKU zaten var mi
    $gql = '{ "query": "query { products(first: 1, query: \"sku:' + $c + '\") { edges { node { id } } } }" }'
    $chk = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 60
    if (@($chk.data.products.edges).Count) { Write-Host "[atla] $c zaten var"; $skip++; Start-Sleep -Milliseconds 200; continue }
    $k = $kat[$c]
    if (-not $k) { Write-Host "[HATA] $c katalogda yok"; $fail++; continue }
    $advies = [double]$k.RecommendedSalesPrice
    if ($advies -le 0) { Write-Host "[atla] $c advies fiyati yok"; $skip++; continue }
    $av = if ($stok.ContainsKey($c)) { $stok[$c] } else { 0 }
    $qty = switch ($av) { 1 { 10 } 2 { 2 } default { 0 } }
    $title = "Cortina $("$($k.Description)".Trim())"
    $body = @{ product = @{
        title = $title
        vendor = 'Cortina'
        tags = "Accu's en Laders"
        status = 'active'
        variants = @(@{
            sku = $c; barcode = "$($k.EANCode)".Trim()
            price = ("{0:0.00}" -f $advies).Replace(',', '.')
            inventory_management = 'shopify'; inventory_policy = 'deny'
        })
    } } | ConvertTo-Json -Depth 5
    try {
        $new = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
        $pid2 = $new.product.id; $invItem = $new.product.variants[0].inventory_item_id
        # stok adedi
        $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/inventory_levels/set.json" -Headers $h -Body (@{ location_id = [long]$loc; inventory_item_id = $invItem; available = $qty } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
        # gorsel (CDN 404 olabilir - urun gorselsiz kalir, Flow taslaga ceker, gorsel gelince acilir)
        $imgOk = 'gorselsiz'
        if ($k.Image) {
            try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products/$pid2/images.json" -Headers $h -Body (@{ image = @{ src = "$($k.Image)" } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 120; $imgOk = 'gorselli' } catch { }
        }
        $made++
        Write-Host "[olusturuldu] $c | $title | EUR $advies | qty $qty | $imgOk"
    } catch { Write-Host "[HATA] $c : $($_.Exception.Message)"; $fail++ }
    Start-Sleep -Milliseconds 500
}
Write-Host "DONE. olusturulan: $made | atlanan: $skip | hata: $fail"
