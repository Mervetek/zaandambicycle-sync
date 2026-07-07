# MAGAZA-GUDUMLU Flex aku baglanti kesfi (2026-07-07).
# "Flex accu" basligi olup battery_options metafield'i OLMAYAN aktif urunleri bulur;
# Accell batteriesandchargers'tan aku article_code'larini cekip bike_battery_links.csv'ye ekler;
# charger_options'i (tum Bosch Flex ayni: Bosch lader 2A/4A) sablondan kopyalar.
# Sebep: bike_battery_links.csv statik -> sonradan eklenen Flex bisikletler seciciSIZ kaliyordu (or. BE501230).
# Sonrasinda rebuild_battery_options.ps1 calistirilmali (battery_options'i kurar). weekly_discovery'ye eklenebilir.
param([string]$ChargerTemplateSku = "BE102916")
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$hj = @{ "X-Shopify-Access-Token" = $tok; "Content-Type" = "application/json" }

# charger sablonu
$q = '{ productVariants(first:1, query:"sku:' + $ChargerTemplateSku + '"){ edges { node { product { co: metafield(namespace:"specs",key:"charger_options"){ value } } } } } }'
$chargerJson = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body (@{query=$q}|ConvertTo-Json)).data.productVariants.edges[0].node.product.co.value
if (-not $chargerJson) { Write-Output "HATA: charger sablonu ($ChargerTemplateSku) bulunamadi"; exit 1 }

# Flex accu + battery_options YOK
$targets = @(); $cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $gq = '{ "query": "query { products(first: 100, query: \"status:active\"' + $after + ') { pageInfo{hasNextPage endCursor} edges { node { id title variants(first:1){edges{node{sku}}} bo:metafield(namespace:\"specs\",key:\"battery_options\"){value} co:metafield(namespace:\"specs\",key:\"charger_options\"){value} } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body $gq -ContentType 'application/json' -TimeoutSec 60
    foreach ($e in $r.data.products.edges) {
        if ($e.node.title -match '(?i)flex accu' -and -not $e.node.bo) {
            $targets += [pscustomobject]@{ id = $e.node.id; sku = "$($e.node.variants.edges[0].node.sku)".Trim(); hasCharger = [bool]$e.node.co }
        }
    }
    $cursor = $r.data.products.pageInfo.endCursor
} while ($r.data.products.pageInfo.hasNextPage)
Write-Output "battery_options'i olmayan Flex urun: $($targets.Count)"

# Accell auth
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }

$links = [System.Collections.ArrayList]@(Import-Csv "$dataDir\bike_battery_links.csv")
$existing = @{}; foreach ($l in $links) { $existing["$($l.bike_sku)|$($l.item_sku)"] = $true }
$newLinks = 0; $chargerSet = 0; $noBat = 0
$mut = 'mutation($id:ID!,$v:String!){ metafieldsSet(metafields:[{ownerId:$id, namespace:"specs", key:"charger_options", type:"json", value:$v}]){ userErrors{message} } }'
foreach ($t in $targets) {
    try {
        $ah["fe-request-id"] = [guid]::NewGuid().ToString()
        $bc = (Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$($t.sku)/batteriesandchargers?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30).result
        $bats = @($bc.Batteries | Where-Object { $_.article_code })
        if (-not $bats.Count) { $noBat++; continue }
        foreach ($b in $bats) {
            $key = "$($t.sku)|$($b.article_code)"
            if (-not $existing.ContainsKey($key)) { [void]$links.Add([pscustomobject]@{ bike_sku = $t.sku; item_sku = "$($b.article_code)"; tur = 'Batteries' }); $existing[$key] = $true; $newLinks++ }
        }
        # charger_options kopyala (yoksa)
        if (-not $t.hasCharger) {
            $body = @{ query = $mut; variables = @{ id = $t.id; v = $chargerJson } } | ConvertTo-Json
            $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
            $chargerSet++
        }
    } catch { Write-Output "  [hata] $($t.sku): $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 300
}
$links | Export-Csv "$dataDir\bike_battery_links.csv" -NoTypeInformation -Encoding utf8
Write-Output "DONE. yeni aku baglantisi: $newLinks | charger yazilan: $chargerSet | Accell'de aku yok: $noBat"
