# Kruitbosch e-bike'larina sabit aku bilgisini yazar (battery_options: tek 'dahil' secenek)
# Kaynak: Kruitbosch attribute 'Accu capaciteit' (Wh)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

$kb = Get-Content "$dataDir\kruitbosch_products_attrs.json" -Raw | ConvertFrom-Json
$batInfo = @{}
foreach ($p in $kb) {
    $a = @{}
    foreach ($at in @($p.Attributes)) { $a[$at.Attribute] = "$($at.AttributeValue)" }
    if ($a.ContainsKey('Accu capaciteit') -and $a['Accu capaciteit'] -match '^\d+') {
        $batInfo["$($p.ProductCode)".Trim()] = [int]($a['Accu capaciteit'] -replace '[^\d].*$','')
    }
}
Write-Host "aku kapasitesi bilinen Kruitbosch kodu: $($batInfo.Count)"

# SKU -> gid haritasi + mevcut battery_options kontrolu icin GraphQL sayfalama
$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { message } } }'
$pending = @()
$cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $gql = '{ "query": "query { products(first: 250, query: \"status:active OR status:draft\"' + $after + ') { pageInfo { hasNextPage endCursor } edges { node { id variants(first: 1) { edges { node { sku } } } metafield(namespace: \"specs\", key: \"battery_options\") { id } } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 60
    $pg = $r.data.products
    foreach ($e in $pg.edges) {
        $sku = "$($e.node.variants.edges[0].node.sku)".Trim()
        if ($sku -and $batInfo.ContainsKey($sku) -and -not $e.node.metafield) {
            $cap = $batInfo[$sku]
            $json = '[{"capacity_wh":' + $cap + ',"additional_cost":0,"barcode":"","included":true}]'
            $pending += @{ ownerId = $e.node.id; namespace = 'specs'; key = 'battery_options'; type = 'json'; value = $json }
        }
    }
    $cursor = $pg.pageInfo.endCursor
    Start-Sleep -Milliseconds 500
} while ($pg.pageInfo.hasNextPage)
Write-Host "aku bilgisi yazilacak urun: $($pending.Count)"

$ok = 0
for ($i = 0; $i -lt $pending.Count; $i += 25) {
    $batch = @($pending[$i..([Math]::Min($i+24, $pending.Count-1))])
    $body = @{ query = $mutation; variables = @{ metafields = $batch } } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
        $ok += @($resp.data.metafieldsSet.metafields).Count
        $ue = @($resp.data.metafieldsSet.userErrors)
        if ($ue.Count) { Write-Host "[uyari] $($ue[0].message)" }
    } catch { Write-Host "[HATA] parti: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 600
}
Write-Host "DONE. yazilan: $ok"
