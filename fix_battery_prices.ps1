# Aku/sarj secici fiyatlarini tedarikci TUKETICI fiyatina (Consumentenprijs/advies) esitler
# 1) Eski site: "Kies een accu/lader" varyasyonlari  2) Shopify: aku urunleri
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"

function N($s) { if ($null -eq $s -or "$s" -eq '') { return $null }; return [double](("$s").Replace(',', '.')) }

# --- tuketici fiyat haritasi ---
$retail = @{}
# Accell canli (aku/sarj SKU'lari icin)
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
# Kruitbosch advies
$kbProducts = Get-Content "$dataDir\kruitbosch_products_raw.json" -Raw | ConvertFrom-Json
foreach ($p in $kbProducts) { $c = "$($p.ProductCode)".Trim(); $rp = N $p.RecommendedSalesPrice; if ($c -and $rp -gt 0) { $retail[$c] = $rp } }

# --- eski site secicileri ---
$choosers = Invoke-RestMethod "$wooBase/products?per_page=100&search=Kies een&status=publish&$wooAuth" -TimeoutSec 60
$allVars = @()
foreach ($p in $choosers) {
    $vs = Invoke-RestMethod "$wooBase/products/$($p.id)/variations?per_page=50&$wooAuth" -TimeoutSec 60
    foreach ($v in $vs) { $allVars += [PSCustomObject]@{ product_id = $p.id; product_name = $p.name; variation_id = $v.id; sku = "$($v.sku)".Trim(); cur_price = N $v.regular_price } }
    Start-Sleep -Milliseconds 200
}
Write-Host "secici secenek: $($allVars.Count)"

# Accell'den eksik retail fiyatlari cek
$needAcc = @($allVars | ForEach-Object { $_.sku } | Where-Object { $_ -and -not $retail.ContainsKey($_) } | Select-Object -Unique)
for ($i = 0; $i -lt $needAcc.Count; $i += 20) {
    $batch = $needAcc[$i..([Math]::Min($i+19, $needAcc.Count-1))]
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($code in $batch) { $a = $r.result.PSObject.Properties[$code]; if ($a -and $a.Value -and $a.Value.retail_price.value) { $retail[$code] = [double]$a.Value.retail_price.value } }
    } catch { }
    Start-Sleep -Milliseconds 300
}
Write-Host "retail fiyat haritasi: $($retail.Count)"

# --- Woo guncelle ---
$ok = 0
$allVars | Where-Object { $_.sku -and $retail.ContainsKey($_.sku) } | Group-Object product_id | ForEach-Object {
    $upd = @()
    foreach ($v in $_.Group) {
        $rp = $retail[$v.sku]
        if ($null -eq $v.cur_price -or [math]::Abs($v.cur_price - $rp) -gt 0.5) {
            $upd += @{ id = [int]$v.variation_id; regular_price = ("{0:0.00}" -f $rp).Replace(',', '.') }
            Write-Host "[WOO] $($v.product_name) #$($_.Name) [$($v.sku)] $($v.cur_price) -> $rp"
        }
    }
    if ($upd.Count) {
        try { $null = Invoke-RestMethod -Method Post -Uri "$wooBase/products/$($_.Name)/variations/batch?$wooAuth" -Body (@{ update = $upd } | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 60; $ok += $upd.Count } catch { Write-Host "[HATA] $($_.Name)" }
        Start-Sleep -Milliseconds 300
    }
}
Write-Host "WOO guncellenen: $ok"

# --- Shopify aku urunleri ---
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$stok = (Invoke-RestMethod -Method Post -Uri "https://8t0pzm-g1.myshopify.com/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$sh = @{ "X-Shopify-Access-Token" = $stok }
$bats = Import-Csv "$dataDir\battery_catalog.csv"
$sok = 0
foreach ($st in 'active','draft') {
    $url = "https://8t0pzm-g1.myshopify.com/admin/api/2024-10/products.json?limit=250&status=$st&fields=id,title,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $sh -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            $v = $p.variants[0]; $sku = "$($v.sku)".Trim()
            if ($sku -and ($bats | Where-Object { $_.sku -eq $sku }) -and $retail.ContainsKey($sku)) {
                $rp = $retail[$sku]
                if ([math]::Abs([double]$v.price - $rp) -gt 0.5) {
                    $body = @{ variant = @{ id = $v.id; price = ("{0:0.00}" -f $rp).Replace(',', '.') } } | ConvertTo-Json
                    try { $null = Invoke-RestMethod -Method Put -Uri "https://8t0pzm-g1.myshopify.com/admin/api/2024-10/variants/$($v.id).json" -Headers $sh -Body $body -ContentType 'application/json' -TimeoutSec 60; $sok++; Write-Host "[SHOPIFY] $($p.title) [$sku] $($v.price) -> $rp" } catch { Write-Host "[HATA shopify] $sku" }
                    Start-Sleep -Milliseconds 300
                }
            }
        }
        $url = $null
        if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}
Write-Host "SHOPIFY guncellenen: $sok"
Write-Host "DONE."
