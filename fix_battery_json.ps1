# battery_options JSON'unu tum bagli bisikletlerde dogru formatla upsert eder (GraphQL metafieldsSet)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# aku bilgisi (Accell)
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0"; "fe-request-id" = [guid]::NewGuid().ToString() }
$bats = Import-Csv "$dataDir\battery_catalog.csv"
$batSkus = @($bats | ForEach-Object { "$($_.sku)".Trim() })
$q = ($batSkus | ForEach-Object { "c=$_" }) -join '&'
$r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
$batInfo = @{}
function Get-Cap($caption) {
    if ("$caption" -match '(\d{3,4})\s*Wh') { return [int]$Matches[1] }
    if ("$caption" -match '(\d{3,4})\s*W\b') { return [int]$Matches[1] }
    return 0
}
foreach ($sku in $batSkus) {
    $a = $r.result.PSObject.Properties[$sku]
    if ($a -and $a.Value) {
        $batInfo[$sku] = @{ ean = "$($a.Value.single_ean)"; retail = [double]$a.Value.retail_price.value; cap = (Get-Cap "$($a.Value.caption) $($a.Value.description)") }
    }
}
# articles sorgusundan donmeyen akuler (or. tekil satisi kapali 41122222): bisiklet-bazli uyumluluk sorgusundan tamamla
$missing = @($batSkus | Where-Object { -not $batInfo.ContainsKey($_) })
if ($missing.Count) {
    $linksAll = Import-Csv "$dataDir\bike_battery_links.csv"
    foreach ($ms in $missing) {
        $bikeRef = ($linksAll | Where-Object { "$($_.item_sku)".Trim() -eq $ms } | Select-Object -First 1).bike_sku
        if (-not $bikeRef) { continue }
        try {
            $ah["fe-request-id"] = [guid]::NewGuid().ToString()
            $bc = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$bikeRef/batteriesandchargers/?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30
            $hit = @($bc.result.Batteries) + @($bc.result.Chargers) | Where-Object { $_.article_code -eq $ms } | Select-Object -First 1
            if ($hit) {
                $batInfo[$ms] = @{ ean = "$($hit.single_ean)"; retail = [double]$hit.retail_price.value; cap = (Get-Cap "$($hit.caption) $($hit.description)") }
                Write-Host "[tamamlandi] $ms : $($batInfo[$ms].cap)Wh retail=$($batInfo[$ms].retail)"
            }
        } catch { Write-Host "[tamamlanamadi] $ms" }
    }
}

# magaza SKU -> product GID
$skuPid = @{}
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            foreach ($v in $p.variants) { $s = "$($v.sku)".Trim(); if ($s -and -not $skuPid.ContainsKey($s)) { $skuPid[$s] = $p.id } }
        }
        $url = $null
        if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}

# JSON'lari kur ve 20'li metafieldsSet partileriyle yaz
$links = Import-Csv "$dataDir\bike_battery_links.csv" | Group-Object bike_sku
$entries = @()
foreach ($g in $links) {
    $bikeSku = "$($g.Name)".Trim()
    if (-not $skuPid.ContainsKey($bikeSku)) { continue }
    $batList = @($g.Group | ForEach-Object { "$($_.item_sku)".Trim() } | Where-Object { $batInfo.ContainsKey($_) } | Select-Object -Unique)
    if (-not $batList.Count) { continue }
    $minRetail = ($batList | ForEach-Object { $batInfo[$_].retail } | Measure-Object -Minimum).Minimum
    $parts = @($batList | Sort-Object { $batInfo[$_].cap } -Descending | ForEach-Object {
        $b = $batInfo[$_]
        $inc = if ($b.retail -eq $minRetail) { 'true' } else { 'false' }
        '{"capacity_wh":' + $b.cap + ',"additional_cost":' + [math]::Round($b.retail - $minRetail, 0) + ',"barcode":"' + $b.ean + '","included":' + $inc + '}'
    })
    $json = '[' + ($parts -join ',') + ']'
    $entries += [PSCustomObject]@{ gid = "gid://shopify/Product/$($skuPid[$bikeSku])"; json = $json }
}
Write-Host "yazilacak bisiklet: $($entries.Count)"

$ok = 0
$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { field message } } }'
for ($i = 0; $i -lt $entries.Count; $i += 20) {
    $batch = $entries[$i..([Math]::Min($i+19, $entries.Count-1))]
    $mfInputs = @($batch | ForEach-Object { @{ ownerId = $_.gid; namespace = 'specs'; key = 'battery_options'; type = 'json'; value = $_.json } })
    $body = @{ query = $mutation; variables = @{ metafields = $mfInputs } } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
        $errs = $resp.data.metafieldsSet.userErrors
        if ($errs -and @($errs).Count) { Write-Host "[uyari] $(@($errs)[0].message)" }
        $ok += @($resp.data.metafieldsSet.metafields).Count
    } catch { Write-Host "[HATA] parti $([int]($i/20)+1): $($_.Exception.Message)" }
    Write-Host "parti $([int]($i/20)+1): toplam $ok"
    Start-Sleep -Milliseconds 600
}
Write-Host "DONE. upsert edilen: $ok"
