param(
    [switch]$Apply,
    [string]$Only
)
# QWIC urunlerini data/qwic_products.json'dan okuyup Shopify'a aktarir.
# QWIC bisikletlerinde aku entegre oldugu icin battery_options/charger_options metafield'i ayarlanmaz.
#
# Kullanim:
#   pwsh -File import_qwic.ps1                  -> KURU CALISMA (listeler, yazmaz)
#   pwsh -File import_qwic.ps1 -Apply           -> Shopify'a yukler
#   pwsh -File import_qwic.ps1 -Apply -Only signal  -> tek model
$ErrorActionPreference = 'Stop'
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }

$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $locationId = 118973399427
$dataDir = Join-Path $PSScriptRoot 'data'
$doneFile = Join-Path $dataDir 'import_qwic_done.txt'
$eu8 = [Text.UTF8Encoding]::new($false)

$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h = @{ "X-Shopify-Access-Token" = $tok }

$allProducts = Get-Content (Join-Path $dataDir 'qwic_products.json') -Raw -Encoding utf8 | ConvertFrom-Json
$done = @{}
if (Test-Path $doneFile) { Get-Content $doneFile | ForEach-Object { $done[$_] = 1 } }

if ($Only) { $allProducts = @($allProducts | Where-Object { $_.slug -eq $Only }) }
$todo = @($allProducts | Where-Object { -not $done.ContainsKey($_.slug) })
Write-Host ("toplam: {0} | kalan: {1}" -f $allProducts.Count, $todo.Count)

# zaten var olan QWIC urunlerini kontrol et (ayni isimle cift olusturma)
$existing = @{}
$url = "https://$shop/admin/api/$api/products.json?limit=250&vendor=QWIC&fields=id,title,handle"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) { $existing[$p.handle] = $p.id }
    $url = $null
    if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
Write-Host ("mevcut QWIC urun: {0}" -f $existing.Count)

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

$created = 0; $skipped = 0; $failed = 0
$idx = 0
foreach ($p in $todo) {
    $idx++
    $slug = $p.slug
    $handle = "qwic-$slug"
    Write-Host ("[$idx/$($todo.Count)] {0} ({1}) EUR {2}" -f $p.name, $slug, $p.price)

    if ($existing.ContainsKey($handle)) {
        Write-Host "  MEVCUT (handle: $handle, id: $($existing[$handle])) -> atlandi"
        Add-Content $doneFile $slug
        $skipped++
        continue
    }

    $bodyHtml = '<p>' + [System.Net.WebUtility]::HtmlEncode($p.description) + '</p>'
    $specTable = Build-SpecsHtml $p.specs
    if ($specTable) { $bodyHtml += "`n<h3>Specificaties</h3>`n$specTable" }

    $tags = @('Bisiklet', 'E-Bikes', 'QWIC')
    if ($p.category) { $tags += $p.category }
    if ($p.colors) { foreach ($c in $p.colors) { $tags += "kleur:$c" } }
    if ($p.frameTypes) { foreach ($ft in $p.frameTypes) { $tags += "frame:$ft" } }

    $imgs = @($p.images | Select-Object -First 8 | ForEach-Object { @{ src = $_ } })

    $product = @{
        title     = $p.name
        handle    = $handle
        vendor    = 'QWIC'
        status    = if ($p.price -gt 0 -and $imgs.Count -gt 0) { 'active' } else { 'draft' }
        body_html = $bodyHtml
        tags      = ($tags -join ', ')
        variants  = @(@{
            sku                  = "QWIC-$($slug.ToUpper())"
            price                = ("{0:0.00}" -f $p.price).Replace(',', '.')
            inventory_management = 'shopify'
            inventory_policy     = 'deny'
        })
    }
    if ($imgs.Count) { $product.images = $imgs }

    if (-not $Apply) {
        Write-Host ("  KURU: {0} | EUR {1} | {2} gorsel | {3} tag | handle={4}" -f $p.name, $p.price, $imgs.Count, $tags.Count, $handle)
        continue
    }

    try {
        $body = @{ product = $product } | ConvertTo-Json -Depth 6
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
        $newPid = $resp.product.id
        $invItem = $resp.product.variants[0].inventory_item_id
        Write-Host ("  OLUSTURULDU: id={0}" -f $newPid)

        Start-Sleep -Milliseconds 300
        try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/inventory_levels/set.json" -Headers $h -Body (@{ location_id = $locationId; inventory_item_id = $invItem; available = 0 } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30 } catch { }

        $gid = "gid://shopify/Product/$newPid"
        $mfs = [System.Collections.ArrayList]::new()
        function AddMf($k, $v, $t = 'single_line_text_field') { $vv = "$v".Trim(); if ($vv) { [void]$mfs.Add(@{ ownerId = $gid; namespace = 'specs'; key = $k; type = $t; value = $vv }) } }

        AddMf 'brand' 'QWIC'
        AddMf 'model' ($p.name -replace '^QWIC\s*', '')
        AddMf 'elo_bike_type' 'Normal'
        if ($p.specs.'Actieradius') { AddMf 'actieradius' $p.specs.'Actieradius' }
        if ($p.specs.'Motor koppel') { AddMf 'motor_koppel' $p.specs.'Motor koppel' }
        if ($p.specs.'Gewicht excl. accu') { AddMf 'gewicht' $p.specs.'Gewicht excl. accu' }
        if ($p.specs.'Accukeuze') { AddMf 'accukeuze' $p.specs.'Accukeuze' }
        if ($p.specs.'Versnellingen') { AddMf 'gears' $p.specs.'Versnellingen' }
        if ($p.specs.'Bandenmaat') { AddMf 'wheelsize' $p.specs.'Bandenmaat' }
        if ($p.specs.'Plaats motor') { AddMf 'plaats_motor' $p.specs.'Plaats motor' }
        if ($p.specs.'Motor brand') { AddMf 'motor_brand' $p.specs.'Motor brand' }
        if ($p.specs.'Oplaadtijd') { AddMf 'oplaadtijd' $p.specs.'Oplaadtijd' }
        if ($p.frameTypes) { AddMf 'frametype' ($p.frameTypes -join ', ') }
        if ($p.colors) { AddMf 'available_colors' ($p.colors -join ', ') }
        AddMf 'source_url' $p.url
        AddMf 'size_variants' '[]' 'json'

        if ($mfs.Count) {
            $mfBody = @{ query = $mutation; variables = @{ metafields = @($mfs) } } | ConvertTo-Json -Depth 6
            try {
                $mfResp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($mfBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
                $errs = $mfResp.data.metafieldsSet.userErrors
                if ($errs -and $errs.Count -gt 0) { Write-Host ("  MF HATA: " + ($errs | ForEach-Object { $_.message } | Select-Object -First 3) -join '; ') }
                else { Write-Host ("  MF: {0} alan ayarlandi" -f $mfs.Count) }
            } catch { Write-Host ("  MF HATA: " + $_.Exception.Message) }
        }

        Add-Content $doneFile $slug
        $created++
    } catch {
        Write-Host ("  HATA: " + $_.Exception.Message)
        $failed++
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ""
if (-not $Apply) {
    Write-Host "KURU CALISMA - Shopify'a DOKUNULMADI. Uygulamak icin: -Apply"
} else {
    Write-Host ("DONE. olusturulan: {0} | atlanan (mevcut): {1} | hata: {2}" -f $created, $skipped, $failed)
}
