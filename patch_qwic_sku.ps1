param(
    [switch]$Apply
)
# Dealer portal SKU kodlarini (HP#####) Shopify QWIC urunlerine eslestirir.
# Eslesme: model + renk + beden + govde tipi
#
# Kullanim:
#   pwsh -File patch_qwic_sku.ps1          -> KURU CALISMA
#   pwsh -File patch_qwic_sku.ps1 -Apply   -> SKU guncelle
$ErrorActionPreference = 'Stop'
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }

$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$dataDir = Join-Path $PSScriptRoot 'data'

$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h = @{ "X-Shopify-Access-Token" = $tok }

# dealer CSV oku
$dealer = Import-Csv (Join-Path $dataDir 'qwic_dealer_products.csv')
Write-Host ("Dealer portal: {0} urun" -f $dealer.Count)

# dealer urunleri icin anahtar olustur
$dealerMap = @{}
foreach ($d in $dealer) {
    $model = $d.model.ToLower().Trim()
    $color = $d.color.ToLower().Trim()
    $size  = $d.size.ToLower().Trim()
    $frame = $d.frame.ToLower().Trim()
    $key = "$model|$color|$size|$frame"
    $dealerMap[$key] = $d
}

# tum QWIC urunlerini cek
$allProducts = @()
$url = "https://$shop/admin/api/$api/products.json?limit=250&vendor=QWIC&fields=id,title,handle,status,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    $allProducts += ($resp.Content | ConvertFrom-Json).products
    $url = $null
    if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
Write-Host ("Shopify QWIC: {0} urun ({1} aktif)" -f $allProducts.Count, ($allProducts | Where-Object { $_.status -eq 'active' }).Count)

# model esleme: handle -> dealer model adi
$handleModelMap = @{
    'signal'         = 'signal'
    'echo-daily'     = 'echo daily'
    'inter-essential'= 'inter essential'
    'inter-plus'     = 'inter plus'
    'inter-tour'     = 'inter tour'
    'inter-daily'    = 'inter daily'
    'mira-daily'     = 'mira daily'
    'mira-tour'      = 'mira tour'
    'elan-daily'     = 'elan daily'
    'elan-flow'      = 'elan flow'
    'elan-tour'      = 'elan tour'
    'atlas-comfort'  = 'atlas comfort'
    'atlas-tour'     = 'atlas tour'
    'atlas-track'    = 'atlas track'
}
$slugKeys = @($handleModelMap.Keys | Sort-Object { $_.Length } -Descending)

function Get-ModelFromHandle([string]$handle) {
    foreach ($s in $slugKeys) {
        if ($handle -eq "qwic-$s" -or $handle -like "qwic-$s-*") {
            return @{ slug = $s; dealerModel = $handleModelMap[$s] }
        }
    }
    return $null
}

# renk, beden, govde tipini title'dan cikar
$knownColors = @(
    'asphalt black', 'jet black', 'matte black', 'midnight blue', 'denim blue',
    'space blue', 'slate blue', 'pebble green', 'khaki green', 'sage green',
    'oker yellow', 'orange', 'concrete grey', 'dusty road', 'desert copper',
    'brushed aluminium', 'chalk white'
)
$knownSizes = @('s', 'm', 'l', 'xl')

function Parse-Title([string]$title) {
    $t = $title.ToLower()
    # frame: dames = lowstep, heren = diamond
    $frame = $null
    if ($t -match '\bdames\b') { $frame = 'lowstep' }
    elseif ($t -match '\bheren\b') { $frame = 'diamond' }
    # beden
    $size = $null
    if ($t -match '\b(xl|s|m|l)\b') {
        $size = $Matches[1]
        if ($t -match '\bxl\b') { $size = 'xl' }
    }
    # renk
    $color = $null
    foreach ($c in $knownColors) {
        if ($t -match [regex]::Escape($c)) { $color = $c; break }
    }
    return @{ frame = $frame; size = $size; color = $color }
}

$matched = 0; $noMatch = 0; $skipped = 0; $updated = 0; $errors = 0
$matchReport = @()

foreach ($prod in $allProducts) {
    if ($prod.status -eq 'archived') { $skipped++; continue }

    $modelInfo = Get-ModelFromHandle $prod.handle
    if (-not $modelInfo) { $noMatch++; continue }

    $parsed = Parse-Title $prod.title
    if (-not $parsed.color -or -not $parsed.size -or -not $parsed.frame) {
        $noMatch++
        continue
    }

    $key = "$($modelInfo.dealerModel)|$($parsed.color)|$($parsed.size)|$($parsed.frame)"
    $dealerProd = $dealerMap[$key]

    if (-not $dealerProd) {
        $noMatch++
        continue
    }

    $variant = $prod.variants[0]
    $currentSku = $variant.sku
    $newSku = $dealerProd.sku

    $matchReport += [PSCustomObject]@{
        Title     = $prod.title
        CurrentSKU = $currentSku
        NewSKU    = $newSku
        DealerPrice = $dealerProd.dealer_price
        Stock     = $dealerProd.stock
    }

    if ($currentSku -eq $newSku) {
        $matched++
        continue
    }

    if (-not $Apply) {
        Write-Host ("[KURU] {0,-60} SKU: {1} -> {2}" -f $prod.title, $currentSku, $newSku)
        $matched++
        continue
    }

    try {
        $body = @{ variant = @{ id = $variant.id; sku = $newSku } } | ConvertTo-Json -Depth 4
        $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/variants/$($variant.id).json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
        Write-Host ("[OK] {0,-60} SKU: {1} -> {2}" -f $prod.title, $currentSku, $newSku)
        $updated++
        $matched++
    } catch {
        Write-Host ("[HATA] {0}: {1}" -f $prod.title, $_.Exception.Message)
        $errors++
    }
    Start-Sleep -Milliseconds 300
}

# rapor
$matchReport | Export-Csv (Join-Path $dataDir 'qwic_sku_match_rapor.csv') -NoTypeInformation -Encoding utf8
Write-Host ""
Write-Host ("SONUC: eslesen={0} | eslesmedi={1} | arsiv={2} | guncellenen={3} | hata={4}" -f $matched, $noMatch, $skipped, $updated, $errors)
Write-Host ("Rapor: data/qwic_sku_match_rapor.csv ({0} satir)" -f $matchReport.Count)
if (-not $Apply) { Write-Host "KURU CALISMA. Uygulamak icin: -Apply" }
