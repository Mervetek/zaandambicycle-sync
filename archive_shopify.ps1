# Shopify'daki mevcut tum urunleri arsivler (geri alinabilir)
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

$ids = Import-Csv "$dataDir\shopify_products.csv" | Select-Object -ExpandProperty product_id -Unique
Write-Host "Arsivlenecek urun: $($ids.Count)"
$ok = 0; $fail = 0; $i = 0
foreach ($id in $ids) {
    $i++
    try {
        $b = @{ product = @{ id = [long]$id; status = "archived" } } | ConvertTo-Json
        $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$id.json" -Headers $h -Body $b -ContentType 'application/json' -TimeoutSec 30
        $ok++
    } catch {
        if ([int]$_.Exception.Response.StatusCode -eq 429) { Start-Sleep -Seconds 2; try { $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$id.json" -Headers $h -Body $b -ContentType 'application/json' -TimeoutSec 30; $ok++ } catch { $fail++ } }
        else { $fail++ }
    }
    if ($i % 50 -eq 0) { Write-Host "$i / $($ids.Count) (ok: $ok, hata: $fail)" }
    Start-Sleep -Milliseconds 550
}
Write-Host "DONE. arsivlenen: $ok, hata: $fail"
