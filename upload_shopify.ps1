# shopify_katalog.csv'yi Shopify'a yukler. Idempotent: islenen SKU'lar log dosyasina yazilir,
# yeniden calistirilirsa kaldigi yerden devam eder (mukerrer olusturmaz).
param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ClientSecret
)
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"
$api = "2024-10"
$doneFile = "$dataDir\upload_done.txt"
$errFile  = "$dataDir\upload_errors.csv"

$body = @{ grant_type = "client_credentials"; client_id = $ClientId; client_secret = $ClientSecret } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $body -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# Ana lokasyon (read_locations izni yok; ID inventory_levels uzerinden tespit edildi)
$locationId = 118973399427
Write-Host "lokasyon: $locationId"

$catalog = Import-Csv "$dataDir\shopify_katalog.csv"
$done = @{}
if (Test-Path $doneFile) { Get-Content $doneFile | ForEach-Object { $done[$_] = 1 } }
$todo = @($catalog | Where-Object { -not $done.ContainsKey($_.sku) })
Write-Host "toplam: $($catalog.Count) | islenmis: $($done.Count) | kalan: $($todo.Count)"

function Invoke-WithRetry($method, $uri, $reqBody) {
    for ($try = 1; $try -le 4; $try++) {
        try {
            if ($reqBody) { return Invoke-RestMethod -Method $method -Uri $uri -Headers $h -Body $reqBody -ContentType 'application/json' -TimeoutSec 60 }
            return Invoke-RestMethod -Method $method -Uri $uri -Headers $h -TimeoutSec 60
        } catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 429 -and $try -lt 4) { Start-Sleep -Seconds (2 * $try); continue }
            throw
        }
    }
}

$ok = 0; $fail = 0; $i = 0
$errors = New-Object System.Collections.ArrayList
foreach ($row in $todo) {
    $i++
    try {
        $qty = [int]$row.qty
        $imgs = @()
        if ($row.images) { $imgs = @(($row.images -split ' \| ') | Where-Object { $_ -match '^https?://' } | ForEach-Object { @{ src = $_ } }) }
        $variant = @{
            sku = $row.sku
            price = if ($row.price) { [string]$row.price } else { "0.00" }
            inventory_management = "shopify"
            inventory_policy = "deny"
        }
        if ($row.barcode) { $variant.barcode = "$($row.barcode)" }
        $product = @{
            title = $row.title
            vendor = $row.vendor
            body_html = $row.body
            status = if ($qty -gt 0 -and $row.price) { "active" } else { "draft" }
            tags = @("Bisiklet", $row.kaynak) -join ', '
            variants = @($variant)
        }
        if ($imgs.Count) { $product.images = $imgs }
        $resp = Invoke-WithRetry Post "https://$shop/admin/api/$api/products.json" (@{ product = $product } | ConvertTo-Json -Depth 6)
        # Urun olustu: yeniden calistirmada mukerrer olmamasi icin hemen kaydet
        Add-Content -Path $doneFile -Value $row.sku
        $invItem = $resp.product.variants[0].inventory_item_id
        Start-Sleep -Milliseconds 300
        try {
            $null = Invoke-WithRetry Post "https://$shop/admin/api/$api/inventory_levels/set.json" (@{ location_id = $locationId; inventory_item_id = $invItem; available = $qty } | ConvertTo-Json)
        } catch {
            [void]$errors.Add([PSCustomObject]@{ sku = $row.sku; title = $row.title; hata = "stok set: $($_.Exception.Message)" })
        }
        $ok++
    } catch {
        $fail++
        [void]$errors.Add([PSCustomObject]@{ sku = $row.sku; title = $row.title; hata = $_.Exception.Message })
    }
    if ($i % 25 -eq 0) { Write-Host "$i / $($todo.Count) (ok: $ok, hata: $fail)" }
    Start-Sleep -Milliseconds 300
}
if ($errors.Count) { $errors | Export-Csv $errFile -NoTypeInformation -Encoding utf8 }
Write-Host "DONE. yuklenen: $ok | hata: $fail"
