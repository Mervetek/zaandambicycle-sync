# SALT-OKUNUR DEDEKTOR (2026-07-07): secicisi OLMASI GEREKEN ama OLMAYAN aktif e-bike'lari bulur + siniflar.
# Amac: yeni bir bisiklet seciciSIZ kalirsa MUSTERI bulmadan SEN gor. Hicbir sey degistirmez; rapor yazar.
# Siniflar: [GERCEK BOSLUK] aksiyon gerek | [BILINCLI] E-Lett paket / NO-BATT / sabit-aku (aksiyon yok).
# daily_sync/health'e eklenebilir. Cortina auto-map RISKLI oldugu icin (API uyumluluk yok) burada TAHMIN yapilmaz - sadece isaretlenir.
param([switch]$FailOnGap)   # workflow'da: GERCEK boşluk varsa exit 1 (adim fail -> GitHub e-posta atar)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $PSScriptRoot "data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$hj = @{ "X-Shopify-Access-Token" = $tok; "Content-Type" = "application/json" }

# --- aktif E-Bike + battery_options YOK ---
$targets = @(); $cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $q = '{ "query": "query { products(first: 100, query: \"status:active tag:E-Bikes\"' + $after + ') { pageInfo{hasNextPage endCursor} edges { node { title vendor variants(first:1){edges{node{sku}}} bo:metafield(namespace:\"specs\",key:\"battery_options\"){value} } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body $q -TimeoutSec 60
    foreach ($e in $r.data.products.edges) {
        if (-not $e.node.bo) { $targets += [pscustomobject]@{ sku = "$($e.node.variants.edges[0].node.sku)".Trim(); vendor = $e.node.vendor; title = $e.node.title } }
    }
    $cursor = $r.data.products.pageInfo.endCursor
} while ($r.data.products.pageInfo.hasNextPage)
Write-Output "aktif E-Bike (secicisi olmayan aday): $($targets.Count)"

# --- Accell auth (NO-BATT kontrolu) ---
$atok = $null
try { $ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
    $atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token } catch {}
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }

$accVendors = @('Batavus','Sparta','Loekie')
$foldVendors = @('UGO','UTO','Bohlt','Eovolt','Dahon','E-Motion')
$real = @(); $intentional = @()
foreach ($t in $targets) {
    if ($t.sku -cmatch '^CELEPRM') { $intentional += [pscustomobject]@{ sku=$t.sku; title=$t.title; sebep='E-Lett paket (aku+sarj dahil)' }; continue }
    if ($foldVendors -contains $t.vendor) { $intentional += [pscustomobject]@{ sku=$t.sku; title=$t.title; sebep='Katlanir - sabit/dahil aku' }; continue }
    if ($accVendors -contains $t.vendor -and $atok) {
        try {
            $ah["fe-request-id"] = [guid]::NewGuid().ToString()
            $bc = (Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$($t.sku)/batteriesandchargers?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30).result
            $bats = @($bc.Batteries | Where-Object { $_.article_code })
            if ($bats.Count) { $real += [pscustomobject]@{ sku=$t.sku; title=$t.title; kaynak="Accell ($($bats.Count) aku VAR)"; aksiyon='rebuild_battery_options + discover_flex_links kapsar' } }
            else { $intentional += [pscustomobject]@{ sku=$t.sku; title=$t.title; sebep='Accell NO-BATT (akusuz satiliyor)' } }
        } catch { $real += [pscustomobject]@{ sku=$t.sku; title=$t.title; kaynak='Accell sorgu hatasi'; aksiyon='elle bak' } }
        Start-Sleep -Milliseconds 250
        continue
    }
    if ($t.vendor -eq 'Cortina') { $real += [pscustomobject]@{ sku=$t.sku; title=$t.title; kaynak='Cortina (KB API uyumluluk vermez)'; aksiyon='PORTAL samenstellen ekranindan ELLE esle -> cortina_secici_plan.csv' }; continue }
    $real += [pscustomobject]@{ sku=$t.sku; title=$t.title; kaynak="diger ($($t.vendor))"; aksiyon='elle incele' }
}

$real | Export-Csv "$dataDir/eksik_secici_raporu.csv" -NoTypeInformation -Encoding utf8
Write-Output ""
Write-Output "=============== DEDEKTOR SONUCU ==============="
Write-Output "[GERCEK BOSLUK] secici lazim -> AKSIYON: $($real.Count)"
$real | ForEach-Object { Write-Output ("   {0} | {1} | {2}" -f $_.sku, $_.title, $_.aksiyon) }
Write-Output ""
Write-Output "[BILINCLI] seciciSIZ dogru (aksiyon YOK): $($intentional.Count)"
$intentional | Group-Object sebep | ForEach-Object { Write-Output ("   {0}: {1}" -f $_.Name, $_.Count) }
Write-Output ""
Write-Output "rapor: data/eksik_secici_raporu.csv"

# workflow alarmi: gercek boşluk varsa adim FAIL (GitHub e-posta atar)
if ($FailOnGap -and $real.Count -gt 0) {
    Write-Output "::error::$($real.Count) GERCEK secici boslugu var - seciciSIZ e-bike(ler): $(($real.sku) -join ', ')"
    exit 1
}
