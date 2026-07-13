# Fiyatli + GORSELLI ama TASLAK kalmis urunleri aktive + yayinla (politika 2026-07-05: fiyatli+gorselli urun vitrinde; taslak sadece fiyatsiz/GORSELSIZ).
# Stok 0'a inince Flow'un taslaga cektigi kapsam-ici urunleri geri getirir. Idempotent, salt-yazma (sadece durum).
# GORSELSIZLER (Conway/Excelsior/Kayza/Noxon eski artiklari, "No Ba" duplikeleri) BILINCLI atlanir - Flow zaten yeniden taslaga ceker + musteriye kirik gorunur.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop = $env:SHOPIFY_SHOP; if (-not $shop) { $shop = "8t0pzm-g1.myshopify.com" }
$api  = "2024-10"
$onlineStore = "gid://shopify/Publication/338868208003"
$pos         = "gid://shopify/Publication/338868240771"

$sb = @{ grant_type='client_credentials'; client_id=$env:SHOPIFY_CLIENT_ID; client_secret=$env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# 1) TASLAK urunleri topla (fiyati>0 olan varyanti olanlar)
$targets = New-Object System.Collections.ArrayList
$url = "https://$shop/admin/api/$api/products.json?limit=250&status=draft&fields=id,title,images,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
        $priced  = @($p.variants | Where-Object { [double]$_.price -gt 0 }).Count -gt 0
        $hasImg  = @($p.images).Count -gt 0
        if ($priced -and $hasImg) { [void]$targets.Add([PSCustomObject]@{ id = $p.id; title = $p.title }) }
    }
    $url = $null
    if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
Write-Output "gorselli fiyatli taslak: $($targets.Count)"

# 2) aktive + yayinla
$ok = 0; $err = 0
$pubMut = 'mutation($id:ID!,$input:[PublicationInput!]!){ publishablePublish(id:$id, input:$input){ userErrors{ message } } }'
foreach ($t in $targets) {
    try {
        $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($t.id).json" -Headers $h -Body (@{ product = @{ id = $t.id; status = 'active' } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
        $vars = @{ id = "gid://shopify/Product/$($t.id)"; input = @(@{ publicationId = $onlineStore }, @{ publicationId = $pos }) } | ConvertTo-Json -Depth 5 -Compress
        $body = @{ query = $pubMut; variables = ($vars | ConvertFrom-Json) } | ConvertTo-Json -Depth 6
        $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        $ue = @($r.data.publishablePublish.userErrors)
        if ($ue.Count -gt 0) { Write-Output "  publish uyari [$($t.title)]: $($ue[0].message)" }
        $ok++
    } catch { $err++; Write-Output "  HATA [$($t.title)]: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 300
}
Write-Output "aktive+yayin: $ok | hata: $err"
