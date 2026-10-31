param(
    [switch]$Apply
)
# QWIC urunlerine batarya secenekleri ekler:
#   1. "QWIC Accu Upgrade" urununu olusturur (540Wh, 625Wh, 756Wh varyantlari)
#   2. Her QWIC bisiklete battery_options metafield'i ayarlar
#   3. QWIC sablonunu product.qwic.json olarak push eder (KULMdX bloguyla)
#
# Kullanim:
#   pwsh -File patch_qwic_battery.ps1           -> KURU CALISMA
#   pwsh -File patch_qwic_battery.ps1 -Apply    -> Shopify'a yaz
$ErrorActionPreference = 'Stop'
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }

$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $locationId = 118973399427
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h = @{ "X-Shopify-Access-Token" = $tok }

$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { message } } }'

# Batarya upgrade fiyati (tum modellerde ayni)
$upgradeCost = 200

# Model -> batarya haritasi
# base_wh: dahil batarya, upgrade_wh: opsiyonel upgrade (null = tek secenek)
$batteryMap = @{
    'signal'         = @{ base_wh = 360; upgrade_wh = $null }
    'echo-daily'     = @{ base_wh = 500; upgrade_wh = 756 }
    'inter-essential'= @{ base_wh = 400; upgrade_wh = 540 }
    'inter-plus'     = @{ base_wh = 400; upgrade_wh = 540 }
    'inter-tour'     = @{ base_wh = 400; upgrade_wh = 540 }
    'inter-daily'    = @{ base_wh = 400; upgrade_wh = 540 }
    'mira-daily'     = @{ base_wh = 756; upgrade_wh = $null }
    'mira-tour'      = @{ base_wh = 756; upgrade_wh = $null }
    'elan-daily'     = @{ base_wh = 500; upgrade_wh = 625 }
    'elan-flow'      = @{ base_wh = 500; upgrade_wh = 625 }
    'elan-tour'      = @{ base_wh = 500; upgrade_wh = 625 }
    'atlas-comfort'  = @{ base_wh = 756; upgrade_wh = $null }
    'atlas-tour'     = @{ base_wh = 756; upgrade_wh = $null }
    'atlas-track'    = @{ base_wh = 756; upgrade_wh = $null }
}

# Handle -> slug esleme (update_qwic.ps1'den kopyala)
$slugKeys = @($batteryMap.Keys | Sort-Object { $_.Length } -Descending)
function Match-Model([string]$handle) {
    foreach ($s in $slugKeys) {
        if ($handle -eq "qwic-$s" -or $handle -like "qwic-$s-*") { return $s }
    }
    return $null
}

# ==================== 1. ACCU UPGRADE URUNU ====================
# Hangi Wh seviyelerine ihtiyacimiz var?
$neededWh = @($batteryMap.Values | Where-Object { $_.upgrade_wh } | ForEach-Object { $_.upgrade_wh } | Sort-Object -Unique)
Write-Host ("Gerekli upgrade Wh seviyeleri: {0}" -f ($neededWh -join ', '))

# Mevcut upgrade urunu var mi kontrol et
$existingUpgrade = $null
$existingVariants = @{}  # wh -> variant_id
$url = "https://$shop/admin/api/$api/products.json?limit=10&handle=qwic-accu-upgrade&fields=id,title,handle,variants"
$resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 30
$existing = ($resp.Content | ConvertFrom-Json).products | Where-Object { $_.handle -eq 'qwic-accu-upgrade' }
if ($existing) {
    $existingUpgrade = $existing
    Write-Host ("Mevcut: '{0}' (id:{1})" -f $existing.title, $existing.id)
    foreach ($v in $existing.variants) {
        $whMatch = [regex]::Match($v.title, '(\d+)\s*Wh')
        if ($whMatch.Success) { $existingVariants[[int]$whMatch.Groups[1].Value] = $v.id }
        Write-Host ("  variant: {0} (id:{1}, sku:{2}, price:{3})" -f $v.title, $v.id, $v.sku, $v.price)
    }
} else {
    Write-Host "Accu upgrade urunu yok, olusturulacak."
}

if (-not $existingUpgrade -and $Apply) {
    $variants = @()
    foreach ($wh in $neededWh) {
        $variants += @{
            title                = "$($wh) Wh"
            sku                  = "QWIC-ACCU-$($wh)WH"
            price                = ("{0:0.00}" -f $upgradeCost).Replace(',', '.')
            inventory_management = 'shopify'
            inventory_policy     = 'continue'
            requires_shipping    = $false
            taxable              = $true
        }
    }
    $product = @{
        title     = 'QWIC Accu Upgrade'
        handle    = 'qwic-accu-upgrade'
        vendor    = 'QWIC'
        status    = 'active'
        body_html = '<p>Upgrade naar een grotere accu voor meer actieradius. Dit product wordt automatisch aan uw winkelwagen toegevoegd wanneer u een grotere accu kiest bij een QWIC e-bike.</p>'
        tags      = 'Accu, QWIC, Accessoire, verberg'
        variants  = $variants
    }
    try {
        $body = @{ product = $product } | ConvertTo-Json -Depth 6
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        $existingUpgrade = $resp.product
        Write-Host ("[OLUSTURULDU] QWIC Accu Upgrade (id:{0})" -f $resp.product.id)
        foreach ($v in $resp.product.variants) {
            $whMatch = [regex]::Match($v.title, '(\d+)\s*Wh')
            if ($whMatch.Success) { $existingVariants[[int]$whMatch.Groups[1].Value] = $v.id }
            Write-Host ("  variant: {0} (id:{1})" -f $v.title, $v.id)
        }
    } catch { Write-Host ("[HATA] Accu urunu olusturulamadi: {0}" -f $_.Exception.Message) }
    Start-Sleep -Milliseconds 500
}

# ==================== 2. BATTERY_OPTIONS METAFIELD ====================
# Tum QWIC bisikletlerini cek
$allProducts = @()
$url = "https://$shop/admin/api/$api/products.json?limit=250&vendor=QWIC&fields=id,title,handle,status"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    $allProducts += ($resp.Content | ConvertFrom-Json).products
    $url = $null
    if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
Write-Host ("")
Write-Host ("QWIC bisiklet: {0} (aktif: {1})" -f $allProducts.Count, ($allProducts | Where-Object { $_.status -eq 'active' }).Count)

# accu-upgrade urununun kendisini ve arsivli urunleri atla
$updated = 0; $skipped = 0; $noMatch = 0
foreach ($prod in $allProducts) {
    if ($prod.handle -eq 'qwic-accu-upgrade') { continue }
    if ($prod.status -eq 'archived') { $skipped++; continue }

    $slug = Match-Model $prod.handle
    if (-not $slug -or -not $batteryMap.ContainsKey($slug)) { $noMatch++; continue }

    $bmap = $batteryMap[$slug]
    $batts = @()
    # Zonder Accu secenegi (her zaman ilk)
    $batts += @{
        capacity_wh     = 0
        additional_cost = 0
        included        = $false
        variant_id      = ''
        available       = $true
    }
    # Dahil batarya (fiyata dahil)
    $batts += @{
        capacity_wh     = $bmap.base_wh
        additional_cost = 0
        included        = $true
        variant_id      = ''
        available       = $true
    }
    if ($bmap.upgrade_wh) {
        $vid = ''
        if ($existingVariants.ContainsKey($bmap.upgrade_wh)) { $vid = "$($existingVariants[$bmap.upgrade_wh])" }
        $batts += @{
            capacity_wh     = $bmap.upgrade_wh
            additional_cost = $upgradeCost
            included        = $false
            variant_id      = $vid
            available       = $true
        }
    }
    $battsJson = ConvertTo-Json -InputObject @($batts) -Depth 4 -Compress

    if (-not $Apply) {
        $desc = ($batts | ForEach-Object { "$($_.capacity_wh)Wh$(if($_.included){' (dahil)'}else{' (+EUR' + $_.additional_cost + ')'})" }) -join ' / '
        Write-Host ("[KURU] {0,-55} {1}" -f $prod.title, $desc)
        $updated++
        continue
    }

    $gid = "gid://shopify/Product/$($prod.id)"
    $mfs = @(@{
        ownerId   = $gid
        namespace = 'specs'
        key       = 'battery_options'
        type      = 'json'
        value     = $battsJson
    })
    $mfBody = @{ query = $mutation; variables = @{ metafields = @($mfs) } } | ConvertTo-Json -Depth 6
    try {
        $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($mfBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
        Write-Host ("[OK] {0}" -f $prod.title)
        $updated++
    } catch {
        Write-Host ("[HATA] {0}: {1}" -f $prod.title, $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 250
}

Write-Host ""
Write-Host ("SONUC: guncellenen={0} | eslesmedi={1} | arsiv={2}" -f $updated, $noMatch, $skipped)
if (-not $Apply) { Write-Host "KURU CALISMA. Uygulamak icin: -Apply" }
