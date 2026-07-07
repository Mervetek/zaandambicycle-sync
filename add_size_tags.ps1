# specs.framesize metafield'ini "NN cm" etiketi olarak tum urunlere ekler (Framehoogte filtresi icin)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# GraphQL ile id + tags + framesize cek (sayfali)
$items = @()
$cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $gql = '{ "query": "query { products(first: 250, query: \"status:active OR status:draft\"' + $after + ') { pageInfo { hasNextPage endCursor } edges { node { id tags metafield(namespace: \"specs\", key: \"framesize\") { value } } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 60
    $pg = $r.data.products
    foreach ($e in $pg.edges) {
        $fs = $e.node.metafield.value
        if ($fs -and $fs -match '^\d{2}$|^\d{2}\s*cm$|^\d{2}\.\d$') {
            $size = ($fs -replace '[^\d]','')
            $tag = "$size cm"
            if ($e.node.tags -notcontains $tag) {
                $items += [PSCustomObject]@{ id = ($e.node.id -replace '.*/',''); tags = @($e.node.tags); newTag = $tag }
            }
        }
    }
    $cursor = $pg.pageInfo.endCursor
    Start-Sleep -Milliseconds 500
} while ($pg.pageInfo.hasNextPage)
Write-Host "etiket eklenecek urun: $($items.Count)"

$ok = 0; $fail = 0; $i = 0
foreach ($it in $items) {
    $i++
    $newTags = (@($it.tags) + $it.newTag) -join ', '
    for ($try = 1; $try -le 3; $try++) {
        try {
            $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($it.id).json" -Headers $h -Body (@{ product = @{ id = [long]$it.id; tags = $newTags } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
            $ok++; break
        } catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 429 -and $try -lt 3) { Start-Sleep -Seconds 2 } else { $fail++; break }
        }
    }
    if ($i % 50 -eq 0) { Write-Host "$i / $($items.Count) (ok $ok)" }
    Start-Sleep -Milliseconds 450
}
Write-Host "DONE. etiketlenen: $ok | hata: $fail"
