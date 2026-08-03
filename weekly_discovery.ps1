# HAFTALIK MODEL KESFI: iki tedarikcide magazada olmayan yeni modelleri bulur ve tam donanimla ekler
# 1) Kruitbosch: tam katalog cagrisiyla yeni ProductCode tespiti -> import (kruitbosch tarafi)
# 2) Accell: kartopu terim taramasi -> yeni kod tespiti -> import_new_accell.ps1 ile ayni akis
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$dataDir = Join-Path $baseDir "data"
$logDir = Join-Path $baseDir "logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("discovery_" + (Get-Date -Format "yyyyMMdd_HHmm") + ".log")
function L($m) { $line = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $line; Add-Content $log $line }
L "haftalik kesif basladi"

# --- mevcut magaza SKU'lari ---
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://8t0pzm-g1.myshopify.com/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
$existing = New-Object System.Collections.Generic.HashSet[string]
foreach ($st in 'active','draft','archived') {
    $url = "https://8t0pzm-g1.myshopify.com/admin/api/2024-10/products.json?limit=250&status=$st&fields=variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) { foreach ($v in $p.variants) { $s = "$($v.sku)".Trim(); if ($s) { [void]$existing.Add($s) } } }
        $url = $null; if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}
L "magaza SKU: $($existing.Count)"

# --- 1) KRUITBOSCH yeni kodlar ---
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
$newKb = @()
try {
    $kp = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=true&ExcludeBlocked=true&IncludeAttributes=false&IncludeAdditionalImages=false&IncludeOriginalImages=false&IncludeInActive=false" -Headers $kh -TimeoutSec 300
    $newKb = @($kp.Products | Where-Object { "$($_.ProductCode)".Trim() -and -not $existing.Contains("$($_.ProductCode)".Trim()) })
    L "kruitbosch yeni model: $($newKb.Count)"
} catch { L "kruitbosch HATA: $($_.Exception.Message)" }

# --- 2) ACCELL yeni kodlar (kartopu tarama) ---
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$brands = @('Batavus','Sparta','Loekie')
$termsQ = New-Object System.Collections.Generic.Queue[string]
$seenT = New-Object System.Collections.Generic.HashSet[string]
function Add-Term($t) { $t = "$t".Trim().ToLower(); if ($t.Length -ge 3 -and $t -notmatch '^\d+$' -and $t -notmatch '[^a-z0-9\-]' -and -not $seenT.Contains($t)) { [void]$seenT.Add($t); $termsQ.Enqueue($t) } }
$brands | ForEach-Object { Add-Term $_ }
foreach ($row in (Import-Csv "$dataDir\accentry_stok.csv")) { foreach ($w in ("$($row.description)" -split '[\s/]+')) { Add-Term $w } }
$accCodes = New-Object System.Collections.Generic.HashSet[string]
$qc = 0
while ($termsQ.Count -gt 0 -and $qc -lt 400) {
    $t = $termsQ.Dequeue(); $qc++
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/search?text=$([uri]::EscapeDataString($t))&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30
        foreach ($m in @($r.result | Where-Object { $_.article_type -eq 'F' -and $_.brand -in $brands })) {
            foreach ($c in @($m.article_codes)) { [void]$accCodes.Add("$c") }
            foreach ($w in ("$($m.description)" -split '[\s/]+')) { Add-Term $w }
        }
    } catch { }
    Start-Sleep -Milliseconds 250
}
$newAcc = @($accCodes | Where-Object { -not $existing.Contains($_) })
L "accell yeni model: $($newAcc.Count)"

# --- 3) IMPORT ---
if ($newAcc.Count) {
    $newAcc | ForEach-Object { [PSCustomObject]@{ sku = $_ } } | Export-Csv "$dataDir\accell_yeni_kodlar.csv" -NoTypeInformation -Encoding utf8
    if (Test-Path "$dataDir\import_new_done.txt") { Remove-Item "$dataDir\import_new_done.txt" -Force -Confirm:$false }
    L "accell import basliyor: $($newAcc.Count) kod"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $baseDir "import_new_accell.ps1") *>&1 | ForEach-Object { Add-Content $log "  $_" }
}
if ($newKb.Count) {
    # Kruitbosch yeni modelleri: shopify_katalog akisiyla ayni alanlar (basit tek-varyant)
    $locationId = 118973399427
    $kbStocks = @{}
    $codes = @($newKb | ForEach-Object { "$($_.ProductCode)".Trim() })
    for ($i = 0; $i -lt $codes.Count; $i += 100) {
        $batch = $codes[$i..([Math]::Min($i+99, $codes.Count-1))]
        try { $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($batch -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60; foreach ($s in $r.StocksAndPrices) { $kbStocks["$($s.ProductCode)".Trim()] = $s } } catch { }
        Start-Sleep -Milliseconds 350
    }
    $ok = 0
    foreach ($p in $newKb) {
        $code = "$($p.ProductCode)".Trim()
        $s = $kbStocks[$code]
        $qty = 0; if ($s) { switch ([int]$s.AvailabilityId) { 1 { $qty = 10 } 2 { $qty = 2 } } }
        $price = [double]$p.RecommendedSalesPrice
        $brand = ($p.Description -split ' ')[0]
        $product = @{
            title = $p.Description; vendor = $brand
            body_html = $p.DescriptionLong
            status = if ($price -gt 0 -and $p.Image) { 'active' } else { 'draft' }   # stoksuz da vitrinde (politika 2026-07-05)
            tags = "Bisiklet, kruitbosch, $brand"
            variants = @(@{ sku = $code; price = ("{0:0.00}" -f $price).Replace(',', '.'); barcode = "$($p.EANCode)"; inventory_management = 'shopify'; inventory_policy = 'deny' })
        }
        if ($p.Image) { $product.images = @(@{ src = $p.Image }) }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri "https://8t0pzm-g1.myshopify.com/admin/api/2024-10/products.json" -Headers $h -Body (@{ product = $product } | ConvertTo-Json -Depth 6) -ContentType 'application/json' -TimeoutSec 90
            Start-Sleep -Milliseconds 300
            try { $null = Invoke-RestMethod -Method Post -Uri "https://8t0pzm-g1.myshopify.com/admin/api/2024-10/inventory_levels/set.json" -Headers $h -Body (@{ location_id = $locationId; inventory_item_id = $resp.product.variants[0].inventory_item_id; available = $qty } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60 } catch { }
            $ok++
        } catch { L "kb import hata: $code" }
        Start-Sleep -Milliseconds 400
    }
    L "kruitbosch import: $ok yeni urun"
}
# --- KB attribute dosyasini tazele (build_electric_specs Cortina elektrik verisi icin kullanir) ---
# IncludeAttributes=true ile tam attribute'lu katalog; yeni Cortina modelleri de kapsansin (2026-07-30).
try {
    $kpAttr = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=true&ExcludeBlocked=true&IncludeAttributes=true&IncludeAdditionalImages=false&IncludeOriginalImages=false&IncludeInActive=false" -Headers $kh -TimeoutSec 300
    if (@($kpAttr.Products).Count -gt 100) { [IO.File]::WriteAllText("$dataDir\kruitbosch_products_attrs.json", (@($kpAttr.Products) | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false)); L "KB attrs tazelendi: $(@($kpAttr.Products).Count)" }
} catch { L "KB ATTRS TAZELEME HATA: $($_.Exception.Message)" }
# --- ELEKTRIK KOMPONENT + ek genel metafield'lari (Accell specs + KB attrs) - tablodan ONCE ---
# specs.el_components + spec_voorvork/verlichting/slot/drager/standaard yazar (musteri istegi 2026-07-30).
try {
    & (Join-Path $baseDir "build_electric_specs.ps1") -Quiet | ForEach-Object { L "elektrik-spec: $_" }
} catch { L "ELEKTRIK SPEC HATA: $($_.Exception.Message)" }
# --- yeni eklenen urunlerin aciklama tablolari (Specificaties + Elektrische Componenten) ---
# build_specs.ps1 metafield'lari import sirasinda yaziliyor; bu adim gorunur HTML tabloyu tamamlar.
# Idempotent: tablosu zaten dogru olanlari atlar, sadece yeni/degisenler yazilir.
try {
    & (Join-Path $baseDir "build_spec_tables.ps1") -Quiet | ForEach-Object { L "spec-tablo: $_" }
} catch { L "SPEC TABLO HATA: $($_.Exception.Message)" }
L "haftalik kesif bitti"
