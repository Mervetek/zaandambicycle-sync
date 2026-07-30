# Accell markali (Cortina DEGIL) bisikletlerde sarj fiyata DAHIL (2026-07-07 karari) -> charger_options BOS olmali.
# Yeni Accell importlari ara sira yanlis "Bosch lader 2A (220-240V), BES3" (los DEGIL) sarj secicisi kaziniyor
# (2026-07-07'deki 188'lik toplu temizlikten sonra sizmalar oldu, 2026-07-30 musteri sikayeti). Bu adim onlari temizler.
# Cortina'nin "Bosch lader (los) ..." / Sport Drive seciciSINE DOKUNMAZ (cift guvenlik: vendor=Cortina + '(los)' imzasi atlanir).
# Idempotent (zaten [] olan atlanir). daily_sync.ps1 tarafindan cagrilir. Ikincil adim -> exit 0 (kosuyu kirmizi yapmaz).
param([switch]$Quiet)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
function Log($m) { if (-not $Quiet) { Write-Host $m } else { Write-Output $m } }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = 'client_credentials'; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
$mut = 'mutation($m:[MetafieldsSetInput!]!){ metafieldsSet(metafields:$m){ userErrors{message} } }'
$after = $null; $scanned = 0; $fixed = 0; $err = 0
do {
    $aft = if ($after) { ', after:\"' + $after + '\"' } else { '' }
    $q = '{ "query": "{ products(first:100, query:\"status:active\"' + $aft + '){ pageInfo{hasNextPage endCursor} edges{ node{ id title vendor chg:metafield(namespace:\"specs\",key:\"charger_options\"){value} } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($q)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
    if ($r.errors) { Log "GraphQL hata: $($r.errors[0].message)"; break }
    foreach ($e in $r.data.products.edges) {
        $n = $e.node; $scanned++
        $cv = "$($n.chg.value)"
        if (-not $cv -or $cv -eq '[]') { continue }        # zaten bos
        if ($n.vendor -eq 'Cortina') { continue }          # Cortina'da sarj AYRI satilir - dokunma
        if ($cv -notmatch 'Bosch lader') { continue }      # sadece Bosch lader imzasi
        if ($cv -match '\(los\)') { continue }             # Cortina "(los)" imzasi - guvenlik, dokunma
        # Accell-imzali sarj secicisi -> temizle
        $body = @{ query = $mut; variables = @{ m = @(@{ ownerId = $n.id; namespace = 'specs'; key = 'charger_options'; type = 'json'; value = '[]' }) } } | ConvertTo-Json -Depth 8
        try {
            $rr = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
            if (@($rr.data.metafieldsSet.userErrors).Count) { $err++; Log "  [uyari] $($n.title): $($rr.data.metafieldsSet.userErrors[0].message)" }
            else { $fixed++; Log "  temizlendi: $($n.title)" }
        } catch { $err++; Log "  [HATA] $($n.title): $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 200
    }
    $after = if ($r.data.products.pageInfo.hasNextPage) { $r.data.products.pageInfo.endCursor } else { $null }
} while ($after)
Log "sarj-temizlik: tarandi $scanned | temizlenen $fixed | hata $err"
exit 0
