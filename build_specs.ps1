# 863 urune eski urunlerle ayni sadelikte specs.* teknik tablo metafieldlarini yazar
# Kaynak: Kruitbosch Attributes (kruitbosch_products_attrs.json) + Accell articles/{code} specs
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

function Get-Sha1($s) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ---------- SKU -> shopify product id + tags ----------
$skuProd = @{}
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,tags,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            $s = "$($p.variants[0].sku)".Trim()
            if ($s -and -not $skuProd.ContainsKey($s)) { $skuProd[$s] = @{ id = $p.id; ebike = ($p.tags -match 'E-Bikes') } }
        }
        $url = $null
        if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}
Write-Host "shopify SKU: $($skuProd.Count)"

$entries = New-Object System.Collections.ArrayList   # {gid, key, value, type}
function Add-Spec($gid, $key, $val, $type = 'single_line_text_field') {
    $v = "$val".Trim()
    if ($v -and $v -ne 'Geen' -and $v -ne 'False' -and $v -ne 'None') {
        [void]$entries.Add(@{ ownerId = $gid; namespace = 'specs'; key = $key; type = $type; value = $v })
    }
}

# ---------- 1) KRUITBOSCH ----------
$kb = Get-Content "$dataDir\kruitbosch_products_attrs.json" -Raw | ConvertFrom-Json
$kbDone = 0
foreach ($p in $kb) {
    $code = "$($p.ProductCode)".Trim()
    if (-not $skuProd.ContainsKey($code)) { continue }
    $gid = "gid://shopify/Product/$($skuProd[$code].id)"
    $a = @{}
    foreach ($at in @($p.Attributes)) { if ($at.Attribute -and -not $a.ContainsKey($at.Attribute)) { $a[$at.Attribute] = "$($at.AttributeValue)" } }
    $brand = $a['Merk']
    $model = if ($a['Type fiets'] -and $a['Type fiets'] -ne 'Geen') { $a['Type fiets'] } else { ("$($p.Description)" -split ' ')[0..1] -join ' ' }
    Add-Spec $gid 'brand' $brand
    Add-Spec $gid 'model' $model
    Add-Spec $gid 'model_year' $a['Modeljaar']
    Add-Spec $gid 'color_description' $a['Kleur specifiek']
    Add-Spec $gid 'basic_color' $a['Primaire basiskleur']
    Add-Spec $gid 'weight_netto' $a['Gewicht']
    Add-Spec $gid 'wheelsize' $a['Wielmaat']
    Add-Spec $gid 'wheelsize_front' $a['Wielmaat']
    Add-Spec $gid 'frametype' $a['Framemodel']
    Add-Spec $gid 'framesize' $a['Framehoogte']
    Add-Spec $gid 'frame_size' $a['Framehoogte']
    Add-Spec $gid 'material' $a['Framemateriaal']
    Add-Spec $gid 'gears' $a['Aantal versnellingen']
    Add-Spec $gid 'gearsystem_rear_brand' $a['Merk versnellingssysteem']
    Add-Spec $gid 'gearsystem_rear_model' $a['Versnelling']
    Add-Spec $gid 'gearsystem_rear_type' $a['Type versnellingssysteem']
    Add-Spec $gid 'brake_system_front_brand' $a['Merk remsysteem voor']
    Add-Spec $gid 'brake_system_front_type' $a['Type remsysteem voor']
    Add-Spec $gid 'primary_brake_system_rear_model' $a['Remsysteem']
    Add-Spec $gid 'primary_brake_system_rear_type' $a['Remtype']
    if ($skuProd[$code].ebike) { Add-Spec $gid 'elo_bike_type' 'Normal' }
    Add-Spec $gid 'article_number' $code
    Add-Spec $gid 'model_group' (Get-Sha1 "$brand|$model|$($a['Kleur specifiek'])")
    Add-Spec $gid 'size_variants' '[]' 'json'
    $kbDone++
}
Write-Host "kruitbosch spec hazir: $kbDone urun, $($entries.Count) alan"

# ---------- 2) ACCELL ----------
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$accSkus = @(Import-Csv "$dataDir\accentry_stok.csv" | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ -and $skuProd.ContainsKey($_) })
$accDone = 0; $i = 0
foreach ($code in $accSkus) {
    $i++
    try {
        $ah["fe-request-id"] = [guid]::NewGuid().ToString()
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles/$code`?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30
        $art = $r.result
        if (-not $art) { continue }
        $gid = "gid://shopify/Product/$($skuProd[$code].id)"
        # spec sozlugu: code -> value (concat'larda .values altindaki gercek degerler)
        $sv = @{}
        foreach ($sp in @($art.specs)) {
            if ($sp.values) { foreach ($vp in $sp.values.PSObject.Properties) { if (-not $sv.ContainsKey($vp.Name)) { $sv[$vp.Name] = "$($vp.Value.value)" } } }
            elseif ($sp.code -and -not $sv.ContainsKey($sp.code)) { $sv[$sp.code] = "$($sp.value)" }
        }
        $brand = "$($art.brand)"
        $model = ("$($art.description)" -replace "^$brand\s*", '')
        Add-Spec $gid 'brand' $brand
        Add-Spec $gid 'model' $model
        Add-Spec $gid 'model_year' $art.season
        Add-Spec $gid 'framesize' ($sv['HEIGHT'] -replace '\s*cm','')
        Add-Spec $gid 'frame_size' ($sv['HEIGHT'] -replace '\s*cm','')
        Add-Spec $gid 'frametype' $sv['FRAMETYPE']
        Add-Spec $gid 'material' $sv['FRAMEMAT']
        Add-Spec $gid 'gears' $sv['UB-GRNBR']
        Add-Spec $gid 'wheelsize' $sv['UB-WHLSIZR']
        Add-Spec $gid 'wheelsize_front' $sv['UB-WHLSIZF']
        Add-Spec $gid 'brake_system_front_brand' $sv['UB-BRKFBRD']
        Add-Spec $gid 'brake_system_front_model' $sv['UB-BRKFTYP']
        Add-Spec $gid 'brake_system_front_type' $sv['UB-BRKFKIN']
        Add-Spec $gid 'primary_brake_system_rear_brand' $sv['UB-BRKRBRD']
        Add-Spec $gid 'primary_brake_system_rear_model' $sv['UB-BRKTYP']
        Add-Spec $gid 'primary_brake_system_rear_type' $sv['UB-BRKRKIN']
        Add-Spec $gid 'gearsystem_rear_brand' $sv['UB-GEARBRD']
        Add-Spec $gid 'gearsystem_rear_model' $sv['UB-GEARTYP']
        Add-Spec $gid 'gearsystem_rear_type' $sv['UB-GEARKIN']
        if ($sv.ContainsKey('EBSYS')) { Add-Spec $gid 'elo_bike_type' $(if ($art.speed_pedelec) { 'Speed pedelec' } else { 'Normal' }) }
        Add-Spec $gid 'article_number' $code
        Add-Spec $gid 'model_group' (Get-Sha1 "$brand|$model")
        Add-Spec $gid 'size_variants' '[]' 'json'
        $accDone++
    } catch { }
    if ($i % 50 -eq 0) { Write-Host "accell: $i / $($accSkus.Count) (spec yazilan: $accDone)" }
    Start-Sleep -Milliseconds 250
}
Write-Host "accell spec hazir: $accDone urun | TOPLAM alan: $($entries.Count)"

# ---------- 3) metafieldsSet ile yaz (25'li partiler) ----------
$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { field message } } }'
$ok = 0; $err = 0
for ($j = 0; $j -lt $entries.Count; $j += 25) {
    $batch = @($entries[$j..([Math]::Min($j+24, $entries.Count-1))])
    $body = @{ query = $mutation; variables = @{ metafields = $batch } } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
        $ue = @($resp.data.metafieldsSet.userErrors)
        if ($ue.Count) { $err += $ue.Count; if ($err -le 5) { Write-Host "[uyari] $($ue[0].message)" } }
        $ok += @($resp.data.metafieldsSet.metafields).Count
    } catch { $err++; Start-Sleep -Seconds 2 }
    if (($j / 25) % 40 -eq 0) { Write-Host "yazilan metafield: $ok / $($entries.Count)" }
    Start-Sleep -Milliseconds 500
}
Write-Host "DONE. yazilan: $ok | hata: $err"
