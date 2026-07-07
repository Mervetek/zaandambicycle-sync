# Cok bedenli (>1 varyant) urunlerin aciklama GIRIS metnindeki tekil "framemaat NN cm" ifadesini
# gercek bedenlerin listesine cevirir: "framematen 50 en 57 cm" (bedene-notr).
# Sebep: birlesme sirasinda aciklama tek bedenin metninden donduruldu (2026-07-07 musteri hatasi).
# Artikel/EAN artik baslik altinda temanin 'codes' blogu ile dinamik gosteriliyor; bu script sadece giris metnini duzeltir.
# Idempotent: sadece tekil "framemaat \d+ cm" varsa yazar. Sadece body degisirse PUT eder.
param([switch]$WhatIf)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

function NlSizes($nums) {
    $s = @($nums | Sort-Object { [int]$_ } -Unique)
    if ($s.Count -eq 1) { return "$($s[0]) cm" }
    if ($s.Count -eq 2) { return "$($s[0]) en $($s[1]) cm" }
    return (($s[0..($s.Count - 2)] -join ', ') + ' en ' + $s[-1] + ' cm')
}

$updated = 0; $skipped = 0; $noMatch = 0; $cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $gql = '{ "query": "query { products(first: 80, query: \"status:active OR status:draft\"' + $after + ') { pageInfo { hasNextPage endCursor } edges { node { legacyResourceId title bodyHtml variantsCount { count } variants(first: 100) { edges { node { title } } } } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 60
    foreach ($e in $r.data.products.edges) {
        $n = $e.node
        if ([int]$n.variantsCount.count -le 1) { continue }   # sadece cok bedenli
        $body = "$($n.bodyHtml)"
        if ($body -notmatch 'framemaat\s*\d+\s*cm') { $noMatch++; continue }
        # varyant basliklarindan bedenleri cikar
        $sizes = @()
        foreach ($v in $n.variants.edges) { if ("$($v.node.title)" -match '(\d+)\s*cm') { $sizes += $Matches[1] } }
        $sizes = @($sizes | Select-Object -Unique)
        if (-not $sizes.Count) { $skipped++; continue }
        $repl = 'framematen ' + (NlSizes $sizes)
        $newBody = [regex]::Replace($body, 'framemaat\s*\d+\s*cm', $repl, 'IgnoreCase')
        if ($newBody -eq $body) { $skipped++; continue }
        if ($WhatIf) { Write-Host "[WHATIF] $($n.title) -> $repl"; $updated++; continue }
        for ($try = 1; $try -le 3; $try++) {
            try {
                $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($n.legacyResourceId).json" -Headers $h -Body (@{ product = @{ id = [long]$n.legacyResourceId; body_html = $newBody } } | ConvertTo-Json -Depth 3) -ContentType 'application/json' -TimeoutSec 60
                $updated++; break
            } catch { $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }; if ($code -eq 429 -and $try -lt 3) { Start-Sleep -Seconds 2 } else { Write-Host "[HATA] $($n.title): $($_.Exception.Message)"; break } }
        }
        Start-Sleep -Milliseconds 400
    }
    Write-Host "...ilerleme: guncellenen=$updated | atlanan=$skipped | eslesmeyen=$noMatch"
    $cursor = $r.data.products.pageInfo.endCursor
    Start-Sleep -Milliseconds 300
} while ($r.data.products.pageInfo.hasNextPage)
Write-Host "DONE. giris metni duzeltilen: $updated | atlanan: $skipped | framemaat-yok: $noMatch"
