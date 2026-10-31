param([string]$Model)
# QWIC e-bike urunlerini qwic.eu sayfalarindan kaziyip data/qwic_products.json dosyasina kaydeder.
# JSON-LD yapilandirilmis verisi + ek gorsel URL'leri cekilir.
#
# Kullanim:
#   pwsh -File scrape_qwic.ps1              -> tum 13 modeli tarar
#   pwsh -File scrape_qwic.ps1 -Model signal  -> tek model
$ErrorActionPreference = 'Stop'

$base = 'https://qwic.eu'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'
$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }

$slugs = @(
    'signal', 'echo-daily',
    'inter-essential', 'inter-plus', 'inter-tour',
    'mira-daily', 'mira-tour',
    'elan-daily', 'elan-flow', 'elan-tour',
    'atlas-comfort', 'atlas-tour', 'atlas-track'
)
if ($Model) { $slugs = @($Model) }

$products = @()
$idx = 0
foreach ($slug in $slugs) {
    $idx++
    $url = "$base/e-bikes/$slug"
    Write-Host ("[$idx/$($slugs.Count)] $url ...")
    try {
        $resp = Invoke-WebRequest -Uri $url -UserAgent $UA -UseBasicParsing -TimeoutSec 30
        $html = $resp.Content
    } catch {
        Write-Host ("  HATA: " + $_.Exception.Message)
        continue
    }

    # JSON-LD cikar
    $ld = $null
    if ($html -match '(?s)<script[^>]+type="application/ld\+json"[^>]*>(.*?)</script>') {
        try { $ld = $Matches[1] | ConvertFrom-Json } catch { Write-Host "  JSON-LD ayristirilamadi" }
    }
    if (-not $ld) { Write-Host "  JSON-LD bulunamadi, atlandi"; continue }

    # renkleri cikar
    $colors = @()
    if ($ld.color) { $colors = @($ld.color) }

    # gorselleri cikar (JSON-LD + sayfadaki ek gorseller)
    $images = @()
    if ($ld.image) { $images = @($ld.image) }
    # storyblok CDN gorsellerini de tara (JSON-LD'de olmayan detay/lifestyle kareleri)
    $extraImgs = @()
    [regex]::Matches($html, 'https://a\.storyblok\.com/f/[^"''>\s]+\.(png|jpg|jpeg|webp)', 'IgnoreCase') | ForEach-Object {
        $u = $_.Value -replace '/m/\d+x?\d*(/filters.*)?$', ''
        if ($u -notin $images -and $u -notin $extraImgs -and $u -notmatch 'share-image') { $extraImgs += $u }
    }
    $allImages = @($images) + @($extraImgs) | Select-Object -Unique

    # frame tipleri
    $frameTypes = @()
    if ($ld.vehicleConfiguration) { $frameTypes = @($ld.vehicleConfiguration -split ',\s*') }
    if ($ld.additionalProperty) {
        $ft = $ld.additionalProperty | Where-Object { $_.name -eq 'Frame type' } | Select-Object -First 1
        if ($ft) { $frameTypes = @($ft.value -split ',\s*') }
    }

    # spec'leri cikar
    $specs = @{}
    if ($ld.additionalProperty) {
        foreach ($p in $ld.additionalProperty) {
            if ($p.name -and $p.value) { $specs[$p.name] = $p.value }
        }
    }

    # kategori
    $category = ''
    if ($specs['Category']) { $category = $specs['Category'] }

    $product = [ordered]@{
        slug         = $slug
        name         = $ld.name
        url          = $url
        description  = $ld.description
        price        = if ($ld.offers.price) { [double]$ld.offers.price } else { 0 }
        currency     = if ($ld.offers.priceCurrency) { $ld.offers.priceCurrency } else { 'EUR' }
        brand        = 'QWIC'
        category     = $category
        colors       = $colors
        frameTypes   = $frameTypes
        images       = $allImages
        specs        = $specs
    }
    $products += $product
    Write-Host ("  OK: {0} | EUR {1} | {2} renk | {3} gorsel | {4} spec" -f $ld.name, $product.price, $colors.Count, $allImages.Count, $specs.Count)
    Start-Sleep -Milliseconds 500
}

$outPath = Join-Path $dataDir 'qwic_products.json'
$products | ConvertTo-Json -Depth 6 | Set-Content $outPath -Encoding utf8
Write-Host ""
Write-Host ("TOPLAM: {0} urun -> {1}" -f $products.Count, $outPath)
