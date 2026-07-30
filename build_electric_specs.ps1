# E-bike'lara ELEKTRIK KOMPONENT + 5 ek genel spec metafield'i yazar (musteri istegi 2026-07-30).
# Kaynak: Accell (GET /articles/{sku} -> "Elektrische Componenten" grubu, DIREKT) + Kruitbosch (attrs, ESLEME).
#   - specs.el_components : JSON [{label,value}] (elektrik bolumu, build_spec_tables render eder)
#   - specs.spec_voorvork / spec_verlichting / spec_slot / spec_drager / spec_standaard : ek 5 genel satir
# Idempotent (mevcut deger ayniysa yazmaz). Agir (Accell per-bike fetch) -> weekly_discovery'de calisir, daily'de DEGIL.
param([switch]$Quiet, [int]$Limit = 0, [switch]$DryRun)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
function Log($m) { if (-not $Quiet) { Write-Host $m } else { Write-Output $m } }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $gw = "https://api-gateway.accentry.com"
$sb = @{ grant_type = 'client_credentials'; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$stok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $stok }
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "$gw/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }

# --- Kruitbosch attrs (Cortina) yukle ---
$kbAttrs = @{}
$kbFile = Join-Path $PSScriptRoot "data\kruitbosch_products_attrs.json"
if (Test-Path $kbFile) {
    foreach ($p in ([IO.File]::ReadAllText($kbFile, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)) {
        $m = @{}; foreach ($a in $p.Attributes) { $m["$($a.Attribute)"] = "$($a.AttributeValue)" }
        $kbAttrs["$($p.ProductCode)".Trim()] = $m
    }
}
Log "KB attrs yuklendi: $($kbAttrs.Count)"

# elektrik bolumu icin KB attr -> etiket eslemesi (Accell direkt gruptan gelir, esleme gerekmez)
$kbEcMap = [ordered]@{
    'Elektrisch systeem' = 'Electrosysteem E-bike'; 'Accu locatie' = 'Accu Locatie'; 'Accu capaciteit' = 'Battery Capacity'
    'Type display' = 'Display'; 'Display functies' = 'Display Stuurbediening'; 'Maximale snelheid' = 'Max Snelheid'
    'Type motor' = 'Drive Unit'; 'Positie motor' = 'Motor Locatie'; 'Motorkracht' = 'Motor Koppel [Nm]'; 'Vermogen' = 'Vermogen (W)'
}
# ek 5 alan: Accell 'description' adaylari + KB attr adaylari
$accVoorvork = 'Voorvork'; $accSlot = 'Slot'; $accStandaard = 'Standaard'; $accDrager = 'Drager (achter)'
$kbVoorvork = 'Voorvork'; $kbSlot = 'Slot'; $kbStandaard = 'Standaard'; $kbDragerAchter = 'Bagagedrager achter'; $kbKoplamp = 'Verlichting voor'; $kbAchter = 'Verlichting achter'

function EcJsonFromAccell($specs) {
    $ec = @($specs | Where-Object { $_.group.label -eq 'Elektrische Componenten' -and "$($_.value)".Trim() })
    if (-not $ec.Count) { return $null }
    $arr = $ec | ForEach-Object { [PSCustomObject]@{ label = "$($_.description)".Trim(); value = "$($_.value)".Trim() } }
    return ($arr | ConvertTo-Json -Compress -Depth 3)
}
function EcJsonFromKb($attr) {
    $arr = @()
    foreach ($k in $kbEcMap.Keys) { if ($attr.ContainsKey($k) -and "$($attr[$k])".Trim()) { $arr += [PSCustomObject]@{ label = $kbEcMap[$k]; value = "$($attr[$k])".Trim() } } }
    if (-not $arr.Count) { return $null }
    return ($arr | ConvertTo-Json -Compress -Depth 3)
}
function AccSpecVal($specs, $desc) { $x = @($specs | Where-Object { $_.description -eq $desc -and "$($_.value)".Trim() }); if ($x.Count) { "$($x[0].value)".Trim() } else { '' } }

# --- Shopify: aktif+taslak urun -> ilk varyant sku + vendor + mevcut el_components (idempotency) ---
$prodList = @(); $after = $null
do {
    $aft = if ($after) { ', after:\"' + $after + '\"' } else { '' }
    $q = '{ "query": "{ products(first:80, query:\"status:active OR status:draft\"' + $aft + '){ pageInfo{hasNextPage endCursor} edges{ node{ id vendor variants(first:1){edges{node{sku}}} ec:metafield(namespace:\"specs\",key:\"el_components\"){value} } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($q)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
    if ($r.errors) { Log "GraphQL hata: $($r.errors[0].message)"; break }
    foreach ($e in $r.data.products.edges) { $prodList += [PSCustomObject]@{ id = $e.node.id; vendor = "$($e.node.vendor)"; sku = "$($e.node.variants.edges[0].node.sku)".Trim(); curEc = "$($e.node.ec.value)" } }
    $after = if ($r.data.products.pageInfo.hasNextPage) { $r.data.products.pageInfo.endCursor } else { $null }
} while ($after)
Log "magaza urun: $($prodList.Count)"

$mut = 'mutation($m:[MetafieldsSetInput!]!){ metafieldsSet(metafields:$m){ userErrors{message} } }'
$done = 0; $ecWritten = 0; $noData = 0; $err = 0; $i = 0
foreach ($p in $prodList) {
    $i++
    if ($Limit -gt 0 -and $i -gt $Limit) { break }
    if (-not $p.sku) { continue }
    $ecJson = $null; $extra = @{}
    if ($p.vendor -eq 'Cortina') {
        $attr = $kbAttrs["$($p.sku)"]
        if ($attr) {
            $ecJson = EcJsonFromKb $attr
            if ($attr.ContainsKey($kbVoorvork)) { $extra['spec_voorvork'] = "$($attr[$kbVoorvork])".Trim() }
            $vl = @(); if ($attr[$kbKoplamp]) { $vl += "voor: $($attr[$kbKoplamp])" }; if ($attr[$kbAchter]) { $vl += "achter: $($attr[$kbAchter])" }; if ($vl.Count) { $extra['spec_verlichting'] = ($vl -join ' | ') }
            if ($attr.ContainsKey($kbSlot)) { $extra['spec_slot'] = "$($attr[$kbSlot])".Trim() }
            if ($attr.ContainsKey($kbDragerAchter)) { $extra['spec_drager'] = "$($attr[$kbDragerAchter])".Trim() }
            if ($attr.ContainsKey($kbStandaard)) { $extra['spec_standaard'] = "$($attr[$kbStandaard])".Trim() }
        }
    } else {
        # Accell (Batavus/Sparta/Loekie/Raleigh vb.) - per-bike fetch
        try {
            $ah["fe-request-id"] = [guid]::NewGuid().ToString()
            $ar = Invoke-RestMethod -Uri "$gw/articles/$($p.sku)?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30
            $specs = @($ar.result.specs)
            if ($specs.Count) {
                $ecJson = EcJsonFromAccell $specs
                $vv = AccSpecVal $specs $accVoorvork; if ($vv) { $extra['spec_voorvork'] = $vv }
                $kl = AccSpecVal $specs 'Koplamp'; $al = AccSpecVal $specs 'Achterlicht'; $vl = @(); if ($kl) { $vl += "voor: $kl" }; if ($al) { $vl += "achter: $al" }; if ($vl.Count) { $extra['spec_verlichting'] = ($vl -join ' | ') }
                $sl = AccSpecVal $specs $accSlot; if ($sl) { $extra['spec_slot'] = $sl }
                $dr = AccSpecVal $specs $accDrager; if ($dr) { $extra['spec_drager'] = $dr }
                $st = AccSpecVal $specs $accStandaard; if ($st) { $extra['spec_standaard'] = $st }
            }
            Start-Sleep -Milliseconds 250
        } catch { $err++; continue }
    }
    if (-not $ecJson -and -not $extra.Count) { $noData++; continue }
    # metafield listesi kur
    $mf = @()
    if ($ecJson -and $ecJson -ne $p.curEc) { $mf += @{ ownerId = $p.id; namespace = 'specs'; key = 'el_components'; type = 'json'; value = $ecJson }; $ecWritten++ }
    foreach ($k in $extra.Keys) { $mf += @{ ownerId = $p.id; namespace = 'specs'; key = $k; type = 'single_line_text_field'; value = $extra[$k] } }
    if (-not $mf.Count) { $done++; continue }   # zaten guncel
    if ($DryRun) {
        Log "[DRY] $($p.sku) ($($p.vendor)): el=$(if($ecJson){'VAR('+(@($ecJson|ConvertFrom-Json)).Count+' alan)'}else{'yok'}) | ekstra: $($extra.Keys -join ',')"
        if ($ecJson) { Log "      EC: $ecJson" }
        continue
    }
    # metafieldsSet 25'lik parti (tek urun ~6 alan, sorun degil)
    $body = @{ query = $mut; variables = @{ m = $mf } } | ConvertTo-Json -Depth 8
    try {
        $rr = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        if (@($rr.data.metafieldsSet.userErrors).Count) { $err++; Log "  [uyari] $($p.sku): $($rr.data.metafieldsSet.userErrors[0].message)" } else { $done++ }
    } catch { $err++ }
}
Log "elektrik-spec: yazilan/guncel $done | el_components yazilan $ecWritten | veri yok $noData | hata $err"
exit 0
