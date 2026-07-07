# Cortina bisikletlerinin specs.battery_options + charger_options metafield'larini TAZE Kruitbosch verisiyle yazar.
# Model (kullanici karari 2026-07-06): KATI "bayi ile birebir" - sadece AvailabilityId 1/2 secilebilir;
#   Op bestelling(4) / Niet leverbaar(3) / veri donmeyen aku = available:false (gri, "Tijdelijk uitverkocht").
#   Lader'larda disabled gosterim olmadigi icin stokta olmayan lader listeden CIKARILIR.
# Fiyat: tam Kruitbosch advies, included=false (excl. accu). Sema v2: variant_id/available/eta.
# Kaynak: data\cortina_secici_plan.csv (eski site kesfi). Idempotent; daily_sync tarafindan da cagrilir.
param([switch]$Quiet)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
function Log($m) { if (-not $Quiet) { Write-Host $m } else { Write-Output $m } }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$kUser = $env:KRUITBOSCH_USERNAME; $kPass = $env:KRUITBOSCH_PASSWORD
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${kUser}:${kPass}"))
$kh = @{ Authorization = "Basic $pair" }

$plan = Import-Csv "$dataDir\cortina_secici_plan.csv" | Where-Object { $_.magazada -ne 'YOK' -and $_.accu_seti }
$kat = Import-Csv "$dataDir\kruitbosch_ccode_katalog.csv"
$ccodes = @($kat.code)
Log "plan bisikleti: $($plan.Count) | C-kod: $($ccodes.Count)"

# --- taze Kruitbosch stok ---
$stok = @{}
try {
    $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$kUser&Products=$($ccodes -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 120
    foreach ($s in @($r.StocksAndPrices)) { $stok["$($s.ProductCode)".Trim()] = [int]$s.AvailabilityId }
} catch { Log "Kruitbosch stok HATASI: $($_.Exception.Message)" }
Log "taze stok: $($stok.Count)/$($ccodes.Count)"
# GUVENLIK FRENI
if ($stok.Count -lt 8) { Log "FREN: Kruitbosch stok verisi yetersiz - yazma YAPILMADI"; exit 1 }

# --- katalog haritasi (advies, EAN, kapasite) ---
$info = @{}
foreach ($k in $kat) {
    $cap = 0
    $capRaw = "$($k.kapasite_wh)" -split ',' | Select-Object -First 1
    if ("$capRaw".Trim() -cmatch '^(\d{3,4})') { $cap = [int]$Matches[1] }
    if (-not $cap -and "$($k.ad)" -cmatch '(\d{3,4})\s*Wh') { $cap = [int]$Matches[1] }
    if (-not $cap -and "$($k.ad)" -cmatch '[Aa]ccu\D*(\d{3})\b') { $cap = [int]$Matches[1] }
    if (-not $cap -and "$($k.ad)" -cmatch '[Pp]owertube\D*(\d{3})\b') { $cap = [int]$Matches[1] }
    $info[$k.code] = @{ ad = "$($k.ad)".Trim(); ean = "$($k.ean)".Trim(); advies = [double]("$($k.advies)" -replace ',', '.'); cap = $cap }
}

# --- Shopify: C-kod urunlerinin variant_id'leri ---
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
$vid = @{}
$url = "https://$shop/admin/api/$api/products.json?limit=250&collection_id=707890479491&fields=id,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
        foreach ($v in $p.variants) { $s2 = "$($v.sku)".Trim(); if ($s2 -and -not $vid.ContainsKey($s2)) { $vid[$s2] = "$($v.id)" } }
    }
    $url = $null; if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
$eksikVid = @($ccodes | Where-Object { -not $vid.ContainsKey($_) })
if ($eksikVid.Count) { Log "UYARI: variant_id bulunamayan C-kod: $($eksikVid -join ', ')" }

# --- hedef metafield'lar ---
function BatteryJson($codes) {
    $opts = @()
    foreach ($c in ($codes -split '\|' | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)) {
        $i = $info[$c]; if (-not $i -or -not $vid.ContainsKey($c) -or $i.advies -le 0) { continue }
        $avail = ($stok.ContainsKey($c) -and $stok[$c] -in 1,2)
        $opts += [PSCustomObject]@{ cap = $i.cap; cost = $i.advies; ean = $i.ean; v = $vid[$c]; avail = $avail }
    }
    if (-not $opts.Count) { return $null }
    $opts = @($opts | Sort-Object cap, cost)
    $parts = $opts | ForEach-Object { '{"capacity_wh":' + $_.cap + ',"additional_cost":' + $_.cost + ',"barcode":"' + $_.ean + '","included":false,"variant_id":"' + $_.v + '","available":' + $(if ($_.avail) { 'true' } else { 'false' }) + ',"eta":""}' }
    return ('[' + ($parts -join ',') + ']')
}
function ChargerJson($codes) {
    $opts = @()
    foreach ($c in ($codes -split '\|' | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)) {
        $i = $info[$c]; if (-not $i -or -not $vid.ContainsKey($c) -or $i.advies -le 0) { continue }
        if (-not ($stok.ContainsKey($c) -and $stok[$c] -in 1,2)) { continue }   # kati: stoksuz lader listelenmez
        $opts += [PSCustomObject]@{ name = $i.ad; cost = $i.advies; ean = $i.ean; v = $vid[$c] }
    }
    if (-not $opts.Count) { return $null }
    $opts = @($opts | Sort-Object cost)
    $parts = $opts | ForEach-Object { '{"name":"' + ($_.name -replace '"', '') + '","price":' + $_.cost + ',"barcode":"' + $_.ean + '","variant_id":"' + $_.v + '"}' }
    return ('[' + ($parts -join ',') + ']')
}

$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { message } } }'
$pending = @(); $same = 0; $seen = 0
foreach ($p in $plan) {
    $bJson = BatteryJson $p.accu_seti
    $cJson = ChargerJson $p.lader_seti
    if (-not $bJson -and -not $cJson) { continue }
    # urunun gid'i + mevcut degerler
    # DIKKAT: ayni SKU'da arsivlenmis eski ikiz olabilir - sadece aktif/taslak urunu hedefle
    $gql = '{ "query": "query { products(first: 1, query: \"sku:' + $p.bike_sku + ' (status:active OR status:draft)\") { edges { node { id bat: metafield(namespace: \"specs\", key: \"battery_options\") { value } chg: metafield(namespace: \"specs\", key: \"charger_options\") { value } } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 60
    $node = $r.data.products.edges[0].node
    if (-not $node) { continue }
    $seen++
    if ($bJson) {
        if ("$($node.bat.value)" -eq $bJson) { $same++ }
        else { $pending += @{ ownerId = $node.id; namespace = 'specs'; key = 'battery_options'; type = 'json'; value = $bJson } }
    }
    if ($cJson) {
        if ("$($node.chg.value)" -ne $cJson) { $pending += @{ ownerId = $node.id; namespace = 'specs'; key = 'charger_options'; type = 'json'; value = $cJson } }
    }
    Start-Sleep -Milliseconds 150
}
Log "bisiklet: $seen | degismeyen aku: $same | yazilacak metafield: $($pending.Count)"

$ok = 0; $err = 0
for ($i = 0; $i -lt $pending.Count; $i += 25) {
    $batch = @($pending[$i..([Math]::Min($i+24, $pending.Count-1))])
    $body = @{ query = $mutation; variables = @{ metafields = $batch } } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
        $ok += @($resp.data.metafieldsSet.metafields).Count
        $ue = @($resp.data.metafieldsSet.userErrors)
        if ($ue.Count) { $err++; Log "[uyari] $($ue[0].message)" }
    } catch { $err++; Log "[HATA] parti $i : $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 600
}
Log "DONE. yazilan metafield: $ok | hata: $err"
