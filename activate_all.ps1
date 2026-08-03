# POLITIKA 2026-07-05: stoksuzlar dahil, fiyati VE gorseli olan tum taslak urunleri yayina alir.
# (Gorselsizler taslakta kalir - magazadaki Flow otomasyonu onlari zaten geri cevirir.)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

$targets = @()
$url = "https://$shop/admin/api/$api/products.json?limit=250&status=draft&fields=id,title,images,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
        $price = [double]$p.variants[0].price
        $hasImg = @($p.images).Count -gt 0
        if ($price -gt 0 -and $hasImg) { $targets += $p.id }
    }
    $url = $null
    if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 400
}
Write-Host "yayina alinacak taslak: $($targets.Count)"
$ok = 0; $fail = 0; $i = 0
foreach ($id in $targets) {
    $i++
    for ($try = 1; $try -le 3; $try++) {
        try {
            $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$id.json" -Headers $h -Body (@{ product = @{ id = [long]$id; status = 'active' } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
            $ok++; break
        } catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 429 -and $try -lt 3) { Start-Sleep -Seconds 2 } else { $fail++; break }
        }
    }
    if ($i % 50 -eq 0) { Write-Host "$i / $($targets.Count) (ok $ok)" }
    Start-Sleep -Milliseconds 450
}
Write-Host "DONE. yayina alinan: $ok | hata: $fail"
