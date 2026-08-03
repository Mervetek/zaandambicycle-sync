# Basarisiz yuklemeden kalan (arsivli OLMAYAN) urunleri siler
param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ClientSecret
)
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$body = @{ grant_type = "client_credentials"; client_id = $ClientId; client_secret = $ClientSecret } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $body -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

$ids = New-Object System.Collections.ArrayList
foreach ($st in 'draft','active') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        (($resp.Content | ConvertFrom-Json).products) | ForEach-Object { [void]$ids.Add($_.id) }
        $url = $null
        if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 500
    }
}
Write-Host "silinecek (arsivsiz) urun: $($ids.Count)"
$ok = 0; $fail = 0; $i = 0
foreach ($id in $ids) {
    $i++
    try { $null = Invoke-RestMethod -Method Delete -Uri "https://$shop/admin/api/$api/products/$id.json" -Headers $h -TimeoutSec 30; $ok++ }
    catch { if ([int]$_.Exception.Response.StatusCode -eq 429) { Start-Sleep -Seconds 2; try { $null = Invoke-RestMethod -Method Delete -Uri "https://$shop/admin/api/$api/products/$id.json" -Headers $h -TimeoutSec 30; $ok++ } catch { $fail++ } } else { $fail++ } }
    if ($i % 50 -eq 0) { Write-Host "$i / $($ids.Count)" }
    Start-Sleep -Milliseconds 550
}
Write-Host "DONE. silinen: $ok, hata: $fail"
