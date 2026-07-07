# Kesifte bulunan yeni Accell kodlarini Shopify'a tam donanimla aktarir:
# urun + stok + advies fiyat + gorseller + specs tablo + aku baglantilari. Idempotent (done-log).
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $locationId = 118973399427
$doneFile = "$dataDir\import_new_done.txt"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }

function Get-Sha1($s) { $sha = [System.Security.Cryptography.SHA1]::Create(); (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) | ForEach-Object { $_.ToString('x2') }) -join '' }
function Get-Cap($c) { if ("$c" -match '(\d{3,4})\s*Wh') { return [int]$Matches[1] }; if ("$c" -match '(\d{3,4})\s*W\b') { return [int]$Matches[1] }; return 0 }

$newCodes = @(Import-Csv "$dataDir\accell_yeni_kodlar.csv" | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ })
$done = @{}; if (Test-Path $doneFile) { Get-Content $doneFile | ForEach-Object { $done[$_] = 1 } }
$todo = @($newCodes | Where-Object { -not $done.ContainsKey($_) })
Write-Host "yeni kod: $($newCodes.Count) | kalan: $($todo.Count)"

# batch: temel veri + gorseller
$base = @{}
for ($i = 0; $i -lt $todo.Count; $i += 20) {
    $batch = @($todo[$i..([Math]::Min($i+19, $todo.Count-1))])
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($c in $batch) { $a = $r.result.PSObject.Properties[$c]; if ($a -and $a.Value) { $base[$c] = $a.Value } }
    } catch { }
    Start-Sleep -Milliseconds 300
}
Write-Host "temel veri: $($base.Count)"

# lader varyantlari (charger_options icin)
$laderV = @{}
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) { foreach ($v in $p.variants) { $s = "$($v.sku)".Trim(); if ($s) { $laderV[$s] = @{ pid = $p.id; vid = $v.id } } } }
        $url = $null; if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}
$chargerJson = $null
if ($laderV.ContainsKey('BOSCH-LADER-2A-BES3')) {
    $chargerJson = ConvertTo-Json @(
        @{ name = "Bosch lader 2A (220-240V), BES3"; price = 89; barcode = "9999999029448"; variant_id = "$($laderV['BOSCH-LADER-2A-BES3'].vid)" },
        @{ name = "Bosch lader 4A (220-240V), BES3"; price = 129; barcode = "9999999030123"; variant_id = "$($laderV['BOSCH-LADER-4A-BES3'].vid)" }
    ) -Compress
}

$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { message } } }'
$created = 0; $failed = 0; $newLinks = @(); $newStokRows = @()
$idx = 0
foreach ($code in $todo) {
    $idx++
    # Accentry token'i uzun kosuda dolabiliyor: her 30 urunde proaktif yenile
    if ($idx % 30 -eq 0) {
        try { $atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token; $ah.Authentication = "Bearer $atok" } catch { }
    }
    if (-not $base.ContainsKey($code)) { $failed++; continue }
    $a = $base[$code]
    try {
        # detay (specs icin)
        $ah["fe-request-id"] = [guid]::NewGuid().ToString()
        $det = (Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$code`?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30).result
        $sv = @{}
        foreach ($sp in @($det.specs)) {
            if ($sp.values) { foreach ($vp in $sp.values.PSObject.Properties) { if (-not $sv.ContainsKey($vp.Name)) { $sv[$vp.Name] = "$($vp.Value.value)" } } }
            elseif ($sp.code -and -not $sv.ContainsKey($sp.code)) { $sv[$sp.code] = "$($sp.value)" }
        }
        $brand = "$($a.brand)"
        $isEbike = $sv.ContainsKey('EBSYS')
        $typeTag = if ($brand -eq 'Loekie') { 'Kinderfietsen' } elseif ($isEbike) { 'E-Bikes' } else { 'Stads- en toerfietsen' }
        $qty = 0
        if ([int]$a.stock_status -le 2) { $qty = if ([int]$a.stock -gt 0) { [int]$a.stock } else { 5 } }
        $price = [double]$a.retail_price.value
        $imgs = @(@($a.images) | Where-Object { $_ -match '^https?://' } | Select-Object -First 8 | ForEach-Object { @{ src = $_ } })
        $title = ("$($a.description) $($a.caption)").Trim()
        $product = @{
            title = $title; vendor = $brand
            status = if ($price -gt 0 -and $imgs.Count -gt 0) { 'active' } else { 'draft' }   # stoksuz da vitrinde (politika 2026-07-05)
            tags = (@('Bisiklet', 'accell', $typeTag, $brand) -join ', ')
            variants = @(@{ sku = $code; price = ("{0:0.00}" -f $price).Replace(',', '.'); barcode = "$($a.single_ean)"; inventory_management = 'shopify'; inventory_policy = 'deny' })
        }
        if ($imgs.Count) { $product.images = $imgs }
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body (@{ product = $product } | ConvertTo-Json -Depth 6) -ContentType 'application/json' -TimeoutSec 90
        Add-Content $doneFile $code
        $newPid = $resp.product.id
        $invItem = $resp.product.variants[0].inventory_item_id
        Start-Sleep -Milliseconds 300
        try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/inventory_levels/set.json" -Headers $h -Body (@{ location_id = $locationId; inventory_item_id = $invItem; available = $qty } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60 } catch { }
        # specs metafieldlari
        $gid = "gid://shopify/Product/$newPid"
        $mfs = New-Object System.Collections.ArrayList
        function AddMf($k, $v, $t = 'single_line_text_field') { $vv = "$v".Trim(); if ($vv -and $vv -ne 'Geen') { [void]$mfs.Add(@{ ownerId = $gid; namespace = 'specs'; key = $k; type = $t; value = $vv }) } }
        $model = ("$($a.description)" -replace "^$brand\s*", '')
        AddMf 'brand' $brand; AddMf 'model' $model; AddMf 'model_year' $det.season
        AddMf 'framesize' ($sv['HEIGHT'] -replace '\s*cm',''); AddMf 'frame_size' ($sv['HEIGHT'] -replace '\s*cm','')
        AddMf 'frametype' $sv['FRAMETYPE']; AddMf 'material' $sv['FRAMEMAT']; AddMf 'gears' $sv['UB-GRNBR']
        AddMf 'wheelsize' $sv['UB-WHLSIZR']; AddMf 'wheelsize_front' $sv['UB-WHLSIZF']
        AddMf 'brake_system_front_brand' $sv['UB-BRKFBRD']; AddMf 'brake_system_front_model' $sv['UB-BRKFTYP']; AddMf 'brake_system_front_type' $sv['UB-BRKFKIN']
        AddMf 'primary_brake_system_rear_brand' $sv['UB-BRKRBRD']; AddMf 'primary_brake_system_rear_model' $sv['UB-BRKTYP']; AddMf 'primary_brake_system_rear_type' $sv['UB-BRKRKIN']
        AddMf 'gearsystem_rear_brand' $sv['UB-GEARBRD']; AddMf 'gearsystem_rear_model' $sv['UB-GEARTYP']; AddMf 'gearsystem_rear_type' $sv['UB-GEARKIN']
        if ($isEbike) { AddMf 'elo_bike_type' $(if ($det.speed_pedelec) { 'Speed pedelec' } else { 'Normal' }) }
        AddMf 'article_number' $code; AddMf 'model_group' (Get-Sha1 "$brand|$model"); AddMf 'size_variants' '[]' 'json'
        # aku baglantilari (e-bike + flex)
        if ($isEbike -and ($det.mandatory_battery -or $det.has_flex_batt)) {
            try {
                $ah["fe-request-id"] = [guid]::NewGuid().ToString()
                $bc = (Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$code/batteriesandchargers/?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30).result
                $batList = @(@($bc.Batteries) | Where-Object { $_.article_code })
                if ($batList.Count) {
                    $minR = ($batList | ForEach-Object { [double]$_.retail_price.value } | Measure-Object -Minimum).Minimum
                    $parts = @($batList | Sort-Object { Get-Cap "$($_.caption)" } -Descending | ForEach-Object {
                        $inc = if ([double]$_.retail_price.value -eq $minR) { 'true' } else { 'false' }
                        '{"capacity_wh":' + (Get-Cap "$($_.caption)") + ',"additional_cost":' + [math]::Round([double]$_.retail_price.value - $minR, 0) + ',"barcode":"' + $_.single_ean + '","included":' + $inc + '}'
                    })
                    [void]$mfs.Add(@{ ownerId = $gid; namespace = 'specs'; key = 'battery_options'; type = 'json'; value = ('[' + ($parts -join ',') + ']') })
                    AddMf 'order_without_battery' 'No'
                    if ($chargerJson -and @($batList | Where-Object { $_.article_code -match '^\d' }).Count) {
                        [void]$mfs.Add(@{ ownerId = $gid; namespace = 'specs'; key = 'charger_options'; type = 'json'; value = $chargerJson })
                        AddMf 'order_without_charger' 'No'
                    }
                    foreach ($b in $batList) { $newLinks += [PSCustomObject]@{ bike_sku = $code; item_sku = $b.article_code; tur = 'Batteries' } }
                }
            } catch { }
        }
        if ($mfs.Count) {
            $body = @{ query = $mutation; variables = @{ metafields = @($mfs) } } | ConvertTo-Json -Depth 6
            try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60 } catch { }
        }
        $newStokRows += [PSCustomObject]@{ sku = $code; brand = $brand; caption = $a.caption; description = $a.description; stock = $a.stock; stock_status = $a.stock_status; stock_week = $a.stock_week; stock_year = $a.stock_year; gross_price = $a.gross_price.value; retail_price = $a.retail_price.value; collection_status = $a.collection_status; authorized_to_order = $a.authorized_to_order; model_code = $a.model_code; images = (@($a.images) | Select-Object -First 8) -join ' | ' }
        $created++
    } catch { $failed++; Write-Host "[HATA] $code : $($_.Exception.Message)" }
    if ($idx % 15 -eq 0) { Write-Host "$idx / $($todo.Count) (olusan: $created)" }
    Start-Sleep -Milliseconds 400
}
# gunluk senkron kapsami: yeni kodlari accentry_stok.csv'ye ekle
if ($newStokRows.Count) {
    $existing = Import-Csv "$dataDir\accentry_stok.csv"
    ($existing + $newStokRows) | Export-Csv "$dataDir\accentry_stok.csv" -NoTypeInformation -Encoding utf8
}
if ($newLinks.Count) {
    $el = Import-Csv "$dataDir\bike_battery_links.csv"
    ($el + $newLinks) | Export-Csv "$dataDir\bike_battery_links.csv" -NoTypeInformation -Encoding utf8
}
Write-Host "DONE. olusan: $created | hata: $failed | yeni aku baglantisi: $($newLinks.Count)"
