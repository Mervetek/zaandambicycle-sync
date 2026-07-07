# bayat_fiyat_advies_alti.csv'deki 99 bisikletin fiyatini GUNCEL advies'e ceker (kullanici karari 2026-07-07).
# Idempotent. Yedek: eski fiyatlar CSV'nin 'bizde' kolonunda.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30).access_token
$hj = @{ "X-Shopify-Access-Token" = $tok; "Content-Type" = "application/json" }
$rows = @(Import-Csv "$dataDir\bayat_fiyat_advies_alti.csv")
$mut = 'mutation($pid:ID!,$vid:ID!,$p:String!){ productVariantsBulkUpdate(productId:$pid, variants:[{id:$vid, price:$p}]){ userErrors{message} } }'
$ok = 0; $err = 0
foreach ($r in $rows) {
    $adv = ("{0:0.00}" -f [double]$r.advies)
    $q = '{ productVariants(first:5, query:"sku:' + $r.sku + '"){ edges { node { id product{ id status } } } } }'
    try {
        $res = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body (@{query=$q}|ConvertTo-Json) -TimeoutSec 60
        $v = $res.data.productVariants.edges | Where-Object { $_.node.product.status -eq 'ACTIVE' } | Select-Object -First 1
        if (-not $v) { $err++; continue }
        $body = @{ query = $mut; variables = @{ pid = $v.node.product.id; vid = $v.node.id; p = $adv } } | ConvertTo-Json
        $u = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        if ($u.data.productVariantsBulkUpdate.userErrors.Count) { $err++ } else { $ok++ }
    } catch { $err++ }
    Start-Sleep -Milliseconds 250
}
Write-Output "DONE. fiyat guncellenen: $ok | hata: $err (toplam $($rows.Count))"
