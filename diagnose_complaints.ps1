# SALT OKUNUR TESHIS: (1) E-Tide DB7 AL MM 2025 lader fiyatlari (2) Sparta d-Rule baz aku kapasitesi
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

function GetProducts($query) {
    $gql = '{ "query": "query { products(first: 20, query: \"' + $query + '\") { edges { node { title status variants(first: 30) { edges { node { sku } } } bat: metafield(namespace: \"specs\", key: \"battery_options\") { value } chg: metafield(namespace: \"specs\", key: \"charger_options\") { value } } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 30
    return @($r.data.products.edges | ForEach-Object { $_.node })
}

Write-Host "================ 1) CORTINA E-TIDE (AL MM 2025) ================"
foreach ($p in (GetProducts 'title:*E-Tide* status:active')) {
    if ($p.title -notmatch '2025') { continue }
    $skus = (@($p.variants.edges | ForEach-Object { $_.node.sku }) -join ',')
    Write-Host ""
    Write-Host ">> $($p.title) [$skus]"
    Write-Host "   battery: $($p.bat.value)"
    Write-Host "   charger: $($p.chg.value)"
}

Write-Host ""
Write-Host "--- Kruitbosch CANLI lader fiyatlari ---"
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
$codes = 'CBFLADERCB,CBFLADER3ACB,CBOLADER2ALOS,CBOLADER4ALOS,CBOLADER2A,CBOLADER4A'
$r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$codes&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
foreach ($s in $r.StocksAndPrices) {
    $advies = [math]::Round([double]$s.PriceNett * 1.7285, 0)
    "  {0,-16} net={1,7:0.00}  advies(x1.7285)={2,5}  avail={3}  qty={4}" -f $s.ProductCode, $s.PriceNett, $advies, $s.AvailabilityId, $s.StockQuantity
}

Write-Host ""
Write-Host "================ 2) SPARTA D-RULE ================"
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }

foreach ($p in (GetProducts 'title:*d-Rule* status:active')) {
    $skus = @($p.variants.edges | ForEach-Object { "$($_.node.sku)".Trim() } | Where-Object { $_ })
    Write-Host ""
    Write-Host ">> $($p.title) [$($skus -join ',')]"
    Write-Host "   battery: $($p.bat.value)"
    # ilk SKU icin canli Accell: UB-BATCAP + batteriesandchargers
    $sku = $skus[0]
    try {
        $ah["fe-request-id"] = [guid]::NewGuid().ToString()
        $art = (Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$sku`?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30).result
        $batcap = ''
        foreach ($sp in @($art.specs)) { if ($sp.code -match 'UB-BATCAP') { if ($sp.values) { foreach ($vp in $sp.values.PSObject.Properties) { if ($vp.Name -eq 'UB-BATCAP') { $batcap = $vp.Value.value } } } else { $batcap = $sp.value } } }
        Write-Host "   ACCELL bike UB-BATCAP: [$batcap] | Consumentenprijs: $($art.retail_price.value)"
        $ah["fe-request-id"] = [guid]::NewGuid().ToString()
        $bc = (Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$sku/batteriesandchargers/?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30).result
        foreach ($b in @($bc.Batteries)) { "   b&c: $($b.article_code) | $($b.caption) | st=$($b.stock_status) | retail=$($b.retail_price.value)" }
    } catch { Write-Host "   accell sorgu hatasi: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 300
}
