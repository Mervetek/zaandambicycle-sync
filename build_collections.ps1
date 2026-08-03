# Eski sitenin kategori yapisini Shopify'a tasir:
# 1) SKU -> eski site kategorileri eslemesi  2) urunlere etiket+marka yaz  3) ayni isimlerle akilli koleksiyonlar kur
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

$brandNames = 'Cortina','Batavus','Sparta','QWIC','Alpina','Raleigh','Loekie','UGO','Dahon'

function Get-TypeTags($catStr) {
    $tags = @()
    if ($catStr -match 'E-Bikes|E-bikes') { $tags += 'E-Bikes' }
    if ($catStr -match 'Stads|toerfietsen') { $tags += 'Stads- en toerfietsen' }
    if ($catStr -match 'Kinderfietsen') { $tags += 'Kinderfietsen' }
    if ($catStr -match 'Vouwfietsen|Elektrische steps') { $tags += 'Vouwfietsen' }
    if ($catStr -match 'Batterijen') { $tags += "Accu's en Laders" }
    return $tags
}

# --- 1) SKU -> (marka, tip) haritasi: once eski site ---
$ap = Import-Csv "$dataDir\admin_products.csv"
$av = Import-Csv "$dataDir\admin_variations.csv"
$prodMeta = @{}
foreach ($p in $ap) {
    $brand = ($brandNames | Where-Object { $p.categories -match $_ } | Select-Object -First 1)
    $prodMeta[$p.id] = @{ brand = $brand; tags = (Get-TypeTags $p.categories) }
}
$skuMeta = @{}
foreach ($v in $av) { $s = "$($v.sku)".Trim(); if ($s -and $prodMeta.ContainsKey($v.product_id)) { $skuMeta[$s] = $prodMeta[$v.product_id] } }
foreach ($p in $ap) { $s = "$($p.sku)".Trim(); if ($s -and -not $skuMeta.ContainsKey($s)) { $skuMeta[$s] = $prodMeta[$p.id] } }
Write-Host "eski siteden eslenen SKU: $($skuMeta.Count)"

# --- 2) eski sitede olmayan Kruitbosch kodlari icin turetme ---
$kb = Get-Content "$dataDir\kruitbosch_products_raw.json" -Raw | ConvertFrom-Json
$cortinaEbike = 'E-U4|E-Common|E-Tide|E-Blau|E-Nite|E-Foss|E-Mozzo'
$cortinaCity  = '^U4 |^Common|^Tide|^UTO|^Foss|^Mozzo|^Blau|^Milo|^Speed'
foreach ($p in $kb) {
    $code = "$($p.ProductCode)".Trim()
    if (-not $code -or $skuMeta.ContainsKey($code)) { continue }
    $d = $p.Description
    $brand = $null; $tags = @()
    if ($code -match '^A' -or $d -match '^Alpina') { $brand = 'Alpina'; $tags = @('Kinderfietsen') }
    elseif ($d -match 'UGO') { $brand = 'UGO'; $tags = @('Vouwfietsen','E-Bikes') }
    elseif ($d -match 'Dahon') { $brand = 'Dahon'; $tags = @('Vouwfietsen') }
    elseif ($d -match 'Raleigh' -or $code -match '^V25') { $brand = 'Raleigh'; $tags = @('E-Bikes') }
    elseif ($code -match '^C') {
        $brand = 'Cortina'
        if ($d -match $cortinaEbike) { $tags = @('E-Bikes') }
        elseif ($d -match 'Kinder|^Cortina (16|18|20|22|24)') { $tags = @('Kinderfietsen') }
        else { $tags = @('Stads- en toerfietsen') }
    }
    elseif ($code -match '^VF') { $brand = 'UGO'; $tags = @('Vouwfietsen') }
    if ($brand) { $skuMeta[$code] = @{ brand = $brand; tags = $tags } }
}
Write-Host "toplam SKU haritasi: $($skuMeta.Count)"

# --- 3) Shopify urunlerini guncelle (vendor + tags) ---
$updated = 0; $skipped = 0
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,title,vendor,tags,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            $sku = "$($p.variants[0].sku)".Trim()
            $isBattery = $p.tags -match 'Accu'
            $meta = if ($sku -and $skuMeta.ContainsKey($sku)) { $skuMeta[$sku] } else { $null }
            if (-not $meta -and -not $isBattery) { $skipped++; continue }
            $newTags = @('Bisiklet')
            $newVendor = $p.vendor
            if ($isBattery) { $newTags = @('Accu', "Accu's en Laders") }
            else {
                if ($meta.tags) { $newTags += $meta.tags }
                if ($meta.brand) { $newTags += $meta.brand; $newVendor = $meta.brand }
            }
            $tagStr = ($newTags | Select-Object -Unique) -join ', '
            if ($p.tags -ne $tagStr -or $p.vendor -ne $newVendor) {
                try {
                    $body = @{ product = @{ id = $p.id; vendor = $newVendor; tags = $tagStr } } | ConvertTo-Json
                    $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($p.id).json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
                    $updated++
                } catch {
                    if ([int]$_.Exception.Response.StatusCode -eq 429) { Start-Sleep -Seconds 2 }
                }
                Start-Sleep -Milliseconds 350
            }
        }
        $url = $null
        if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Write-Host "guncellenen: $updated | haritasiz: $skipped"
    }
}
Write-Host "urun guncelleme bitti: $updated (haritasiz atlanan: $skipped)"

# --- 4) akilli koleksiyonlar ---
$collections = @(
    @{ title = 'E-Bikes'; tag = 'E-Bikes' },
    @{ title = 'Stads- en toerfietsen'; tag = 'Stads- en toerfietsen' },
    @{ title = 'Kinderfietsen'; tag = 'Kinderfietsen' },
    @{ title = 'Vouwfietsen'; tag = 'Vouwfietsen' },
    @{ title = "Accu's en Laders"; tag = "Accu's en Laders" },
    @{ title = 'Cortina'; tag = 'Cortina' },
    @{ title = 'Batavus'; tag = 'Batavus' },
    @{ title = 'Sparta'; tag = 'Sparta' },
    @{ title = 'Alpina'; tag = 'Alpina' },
    @{ title = 'UGO'; tag = 'UGO' },
    @{ title = 'Raleigh'; tag = 'Raleigh' },
    @{ title = 'Loekie'; tag = 'Loekie' },
    @{ title = 'Alle fietsen'; tag = 'Bisiklet' }
)
# mevcutlari cek (mukerrer onleme)
$existing = @()
try { $existing = (Invoke-RestMethod "https://$shop/admin/api/$api/smart_collections.json?limit=250" -Headers $h -TimeoutSec 30).smart_collections | ForEach-Object { $_.title } } catch { }
$created = 0
foreach ($c in $collections) {
    if ($existing -contains $c.title) { Write-Host "[var] $($c.title)"; continue }
    $body = @{ smart_collection = @{ title = $c.title; rules = @(@{ column = 'tag'; relation = 'equals'; condition = $c.tag }); disjunctive = $false } } | ConvertTo-Json -Depth 5
    try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/smart_collections.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60; $created++; Write-Host "[olusturuldu] $($c.title)" } catch { Write-Host "[HATA] $($c.title): $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 400
}
Write-Host "DONE. koleksiyon olusturulan: $created"
