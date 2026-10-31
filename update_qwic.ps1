param(
    [switch]$Apply,
    [switch]$CreateMissing
)
# Mevcut QWIC urunlerini qwic.eu verileriyle gunceller:
#   - body_html: aciklama + spec tablosu
#   - metafields: brand, model, actieradius, motor, aku, vb.
#   - Opsiyonel: eksik modeller icin yeni urun olusturur (-CreateMissing)
#
# Kullanim:
#   pwsh -File update_qwic.ps1                              -> KURU CALISMA
#   pwsh -File update_qwic.ps1 -Apply                       -> sadece guncelle
#   pwsh -File update_qwic.ps1 -Apply -CreateMissing        -> guncelle + eksik modelleri olustur
$ErrorActionPreference = 'Stop'
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }

$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $locationId = 118973399427
$dataDir = Join-Path $PSScriptRoot 'data'

$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h = @{ "X-Shopify-Access-Token" = $tok }

$scraped = Get-Content (Join-Path $dataDir 'qwic_products.json') -Raw -Encoding utf8 | ConvertFrom-Json
$modelMap = @{}
foreach ($m in $scraped) { $modelMap[$m.slug] = $m }
Write-Host ("qwic_products.json: {0} model yuklendi" -f $modelMap.Count)

# tum QWIC urunlerini cek
$allProducts = @()
$url = "https://$shop/admin/api/$api/products.json?limit=250&vendor=QWIC&fields=id,title,handle,status,body_html,variants,images,tags"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    $allProducts += ($resp.Content | ConvertFrom-Json).products
    $url = $null
    if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
Write-Host ("Shopify QWIC: {0} urun ({1} aktif, {2} draft, {3} archived)" -f $allProducts.Count,
    ($allProducts | Where-Object { $_.status -eq 'active' }).Count,
    ($allProducts | Where-Object { $_.status -eq 'draft' }).Count,
    ($allProducts | Where-Object { $_.status -eq 'archived' }).Count)

# her urunu scraped modelle eslestir
$slugs = @($modelMap.Keys | Sort-Object { $_.Length } -Descending)
function Match-Model([string]$handle) {
    foreach ($s in $slugs) {
        if ($handle -eq "qwic-$s" -or $handle -like "qwic-$s-*") { return $s }
    }
    return $null
}

$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { message } } }'

function Build-SpecsHtml($specs) {
    $skip = @('Category', 'Family', 'Frame type', 'Motor brand', 'Battery capacity', 'Drive', 'Vanafprijs')
    $rows = @()
    foreach ($kv in $specs.PSObject.Properties) {
        if ($kv.Name -in $skip) { continue }
        $rows += '<tr><td style="padding:6px 12px;border-bottom:1px solid #eee;font-weight:600;white-space:nowrap">{0}</td><td style="padding:6px 12px;border-bottom:1px solid #eee">{1}</td></tr>' -f [System.Net.WebUtility]::HtmlEncode($kv.Name), [System.Net.WebUtility]::HtmlEncode($kv.Value)
    }
    if (-not $rows.Count) { return '' }
    '<table style="width:100%;border-collapse:collapse;margin-top:16px"><tbody>' + ($rows -join "`n") + '</tbody></table>'
}

# GUNCELLEME
$updated = 0; $noMatch = 0; $skippedArch = 0; $errors = 0
$matchedSlugs = @{}
foreach ($prod in $allProducts) {
    if ($prod.status -eq 'archived') { $skippedArch++; continue }

    $slug = Match-Model $prod.handle
    if (-not $slug) {
        $noMatch++
        continue
    }
    $matchedSlugs[$slug] = $true
    $m = $modelMap[$slug]

    $bodyHtml = '<p>' + [System.Net.WebUtility]::HtmlEncode($m.description) + '</p>'
    $specTable = Build-SpecsHtml $m.specs
    if ($specTable) { $bodyHtml += "`n<h3>Specificaties</h3>`n$specTable" }

    $tags = @($prod.tags -split ',\s*')
    foreach ($t in @('E-Bikes', 'QWIC')) { if ($t -notin $tags) { $tags += $t } }
    if ($m.category -and $m.category -notin $tags) { $tags += $m.category }
    $newTags = ($tags | Select-Object -Unique) -join ', '

    if (-not $Apply) {
        Write-Host ("[KURU] {0,-55} -> model:{1} | fiyat:EUR{2}" -f $prod.title, $slug, $m.price)
        continue
    }

    try {
        $upd = @{
            product = @{
                id        = $prod.id
                body_html = $bodyHtml
                tags      = $newTags
            }
        }
        $body = $upd | ConvertTo-Json -Depth 6
        $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($prod.id).json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        Write-Host ("[OK] {0}" -f $prod.title)

        # metafields
        $gid = "gid://shopify/Product/$($prod.id)"
        $mfs = [System.Collections.ArrayList]::new()
        function AddMf($k, $v, $t = 'single_line_text_field') { $vv = "$v".Trim(); if ($vv) { [void]$mfs.Add(@{ ownerId = $gid; namespace = 'specs'; key = $k; type = $t; value = $vv }) } }

        AddMf 'brand' 'QWIC'
        AddMf 'model' ($m.name -replace '^QWIC\s*', '')
        AddMf 'elo_bike_type' 'Normal'
        if ($m.specs.'Actieradius') { AddMf 'actieradius' $m.specs.'Actieradius' }
        if ($m.specs.'Motor koppel') { AddMf 'motor_koppel' $m.specs.'Motor koppel' }
        if ($m.specs.'Gewicht excl. accu') { AddMf 'gewicht' $m.specs.'Gewicht excl. accu' }
        if ($m.specs.'Accukeuze') { AddMf 'accukeuze' $m.specs.'Accukeuze' }
        if ($m.specs.'Versnellingen') { AddMf 'gears' $m.specs.'Versnellingen' }
        if ($m.specs.'Bandenmaat') { AddMf 'wheelsize' $m.specs.'Bandenmaat' }
        if ($m.specs.'Plaats motor') { AddMf 'plaats_motor' $m.specs.'Plaats motor' }
        if ($m.specs.'Motor brand') { AddMf 'motor_brand' $m.specs.'Motor brand' }
        if ($m.specs.'Oplaadtijd') { AddMf 'oplaadtijd' $m.specs.'Oplaadtijd' }
        if ($m.frameTypes) { AddMf 'frametype' ($m.frameTypes -join ', ') }
        if ($m.colors) { AddMf 'available_colors' ($m.colors -join ', ') }
        AddMf 'source_url' $m.url

        if ($mfs.Count) {
            $mfBody = @{ query = $mutation; variables = @{ metafields = @($mfs) } } | ConvertTo-Json -Depth 6
            try {
                $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($mfBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
            } catch { Write-Host ("  MF HATA: " + $_.Exception.Message) }
        }

        # gorsel yoksa ekle (ilk 5 model gorseli)
        if ($prod.images.Count -le 1) {
            $imgUrls = @($m.images | Select-Object -First 5)
            foreach ($imgUrl in $imgUrls) {
                try {
                    $imgBody = @{ image = @{ src = $imgUrl } } | ConvertTo-Json -Depth 4
                    $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products/$($prod.id)/images.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($imgBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
                    Start-Sleep -Milliseconds 300
                } catch { }
            }
            Write-Host ("  +{0} gorsel eklendi" -f $imgUrls.Count)
        }

        $updated++
    } catch {
        Write-Host ("[HATA] {0}: {1}" -f $prod.title, $_.Exception.Message)
        $errors++
    }
    Start-Sleep -Milliseconds 400
}

# EKSIK MODELLER
$missingSlugs = @($modelMap.Keys | Where-Object { -not $matchedSlugs.ContainsKey($_) })
if ($missingSlugs.Count -gt 0) {
    Write-Host ""
    Write-Host ("EKSIK MODELLER ({0}): {1}" -f $missingSlugs.Count, ($missingSlugs -join ', '))
    if ($CreateMissing -and $Apply) {
        foreach ($slug in $missingSlugs) {
            $m = $modelMap[$slug]
            $handle = "qwic-$slug"
            $bodyHtml = '<p>' + [System.Net.WebUtility]::HtmlEncode($m.description) + '</p>'
            $specTable = Build-SpecsHtml $m.specs
            if ($specTable) { $bodyHtml += "`n<h3>Specificaties</h3>`n$specTable" }

            $tags = @('Bisiklet', 'E-Bikes', 'QWIC')
            if ($m.category) { $tags += $m.category }
            $imgs = @($m.images | Select-Object -First 8 | ForEach-Object { @{ src = $_ } })

            $product = @{
                title     = $m.name
                handle    = $handle
                vendor    = 'QWIC'
                status    = 'draft'
                body_html = $bodyHtml
                tags      = ($tags -join ', ')
                variants  = @(@{
                    sku                  = "QWIC-$($slug.ToUpper())"
                    price                = ("{0:0.00}" -f $m.price).Replace(',', '.')
                    inventory_management = 'shopify'
                    inventory_policy     = 'deny'
                })
            }
            if ($imgs.Count) { $product.images = $imgs }

            try {
                $body = @{ product = $product } | ConvertTo-Json -Depth 6
                $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
                Write-Host ("[YENI] {0} (id: {1}, draft)" -f $m.name, $resp.product.id)

                $gid = "gid://shopify/Product/$($resp.product.id)"
                $mfs = [System.Collections.ArrayList]::new()
                AddMf 'brand' 'QWIC'; AddMf 'model' ($m.name -replace '^QWIC\s*', ''); AddMf 'elo_bike_type' 'Normal'
                if ($m.specs.'Actieradius') { AddMf 'actieradius' $m.specs.'Actieradius' }
                if ($m.specs.'Motor koppel') { AddMf 'motor_koppel' $m.specs.'Motor koppel' }
                if ($m.specs.'Accukeuze') { AddMf 'accukeuze' $m.specs.'Accukeuze' }
                if ($m.specs.'Plaats motor') { AddMf 'plaats_motor' $m.specs.'Plaats motor' }
                if ($m.frameTypes) { AddMf 'frametype' ($m.frameTypes -join ', ') }
                if ($m.colors) { AddMf 'available_colors' ($m.colors -join ', ') }
                AddMf 'source_url' $m.url

                if ($mfs.Count) {
                    $mfBody = @{ query = $mutation; variables = @{ metafields = @($mfs) } } | ConvertTo-Json -Depth 6
                    try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($mfBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60 } catch { }
                }
            } catch { Write-Host ("[HATA] {0}: {1}" -f $m.name, $_.Exception.Message); $errors++ }
            Start-Sleep -Milliseconds 500
        }
    } elseif (-not $CreateMissing) {
        Write-Host "  (olusturmak icin: -CreateMissing ekleyin)"
    }
}

Write-Host ""
if (-not $Apply) {
    Write-Host "KURU CALISMA tamamlandi. Uygulamak icin: -Apply"
    Write-Host ("  eslesecek: {0} | arsiv (atlanacak): {1} | eslesmeyecek: {2} | eksik model: {3}" -f ($allProducts.Count - $skippedArch - $noMatch), $skippedArch, $noMatch, $missingSlugs.Count)
} else {
    Write-Host ("DONE. guncellenen: {0} | hata: {1} | arsiv atlanan: {2} | eslesmedi: {3}" -f $updated, $errors, $skippedArch, $noMatch)
}
