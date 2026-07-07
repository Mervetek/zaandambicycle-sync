# Xtra temasinin bekledigi specs.battery_options / charger_options metafieldlarini yeni urunlere kurar
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

function N($s) { if ($null -eq $s -or "$s" -eq '') { return $null }; return [double](("$s").Replace(',', '.')) }

# --- 1) Accell'den aku EAN'lari + retail ---
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0"; "fe-request-id" = [guid]::NewGuid().ToString() }
$bats = Import-Csv "$dataDir\battery_catalog.csv"
$batSkus = @($bats | ForEach-Object { "$($_.sku)".Trim() })
$q = ($batSkus | ForEach-Object { "c=$_" }) -join '&'
$r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
$batInfo = @{}
foreach ($sku in $batSkus) {
    $a = $r.result.PSObject.Properties[$sku]
    if ($a -and $a.Value) {
        $cap = 0; if ("$($a.Value.caption)" -match '(\d{3,4})\s*Wh') { $cap = [int]$Matches[1] }
        $batInfo[$sku] = @{ ean = "$($a.Value.single_ean)"; retail = [double]$a.Value.retail_price.value; cap = $cap; incl_lader = ("$($a.Value.caption)" -match 'Incl. Lader') }
    }
}
Write-Host "aku bilgisi: $($batInfo.Count)"

# --- 2) magaza SKU -> product/variant haritasi ---
$skuMap = @{}
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            foreach ($v in $p.variants) { $s = "$($v.sku)".Trim(); if ($s -and -not $skuMap.ContainsKey($s)) { $skuMap[$s] = @{ pid = $p.id; vid = $v.id } } }
        }
        $url = $null
        if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}
Write-Host "magaza SKU: $($skuMap.Count)"

# --- 3) aku urunlerine barkod (EAN) yaz ---
foreach ($sku in $batSkus) {
    if ($skuMap.ContainsKey($sku) -and $batInfo.ContainsKey($sku) -and $batInfo[$sku].ean) {
        try { $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/variants/$($skuMap[$sku].vid).json" -Headers $h -Body (@{ variant = @{ id = $skuMap[$sku].vid; barcode = $batInfo[$sku].ean } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60 } catch { }
        Start-Sleep -Milliseconds 250
    }
}
Write-Host "aku barkodlari yazildi"

# --- 4) Bosch lader urunu (yoksa olustur) ---
$laderSku2A = 'BOSCH-LADER-2A-BES3'; $laderSku4A = 'BOSCH-LADER-4A-BES3'
$lader = $null
if ($skuMap.ContainsKey($laderSku2A)) { $lader = @{ v2 = $skuMap[$laderSku2A].vid; v4 = $skuMap[$laderSku4A].vid } }
else {
    $body = @{ product = @{
        title = "Bosch lader BES3 (220-240V)"; vendor = "Bosch"; status = "active"; tags = "Accu, Accu's en Laders"
        options = @(@{ name = "Vermogen" })
        variants = @(
            @{ option1 = "2A"; sku = $laderSku2A; price = "89.00"; inventory_management = $null },
            @{ option1 = "4A"; sku = $laderSku4A; price = "129.00"; inventory_management = $null }
        )
    } } | ConvertTo-Json -Depth 6
    $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
    $lader = @{ v2 = ($resp.product.variants | Where-Object { $_.option1 -eq '2A' }).id; v4 = ($resp.product.variants | Where-Object { $_.option1 -eq '4A' }).id }
    Write-Host "lader urunu olusturuldu: $($resp.product.id)"
}
$chargerJson = ConvertTo-Json @(
    @{ name = "Bosch lader 2A (220-240V), BES3"; price = 89; barcode = "9999999029448"; variant_id = "$($lader.v2)" },
    @{ name = "Bosch lader 4A (220-240V), BES3"; price = 129; barcode = "9999999030123"; variant_id = "$($lader.v4)" }
) -Compress

# --- 5) her bagli bisiklete metafieldlar ---
$links = Import-Csv "$dataDir\bike_battery_links.csv" | Group-Object bike_sku
$done = 0; $skip = 0
foreach ($g in $links) {
    $bikeSku = "$($g.Name)".Trim()
    if (-not $skuMap.ContainsKey($bikeSku)) { $skip++; continue }
    $bikePid = $skuMap[$bikeSku].pid
    $batList = @($g.Group | ForEach-Object { "$($_.item_sku)".Trim() } | Where-Object { $batInfo.ContainsKey($_) } | Select-Object -Unique)
    if (-not $batList.Count) { $skip++; continue }
    $minRetail = ($batList | ForEach-Object { $batInfo[$_].retail } | Measure-Object -Minimum).Minimum
    $opts = @($batList | Sort-Object { $batInfo[$_].cap } -Descending | ForEach-Object {
        $b = $batInfo[$_]
        @{ capacity_wh = $b.cap; additional_cost = [math]::Round($b.retail - $minRetail, 0); barcode = $b.ean; included = ($b.retail -eq $minRetail) }
    })
    $batJson = ConvertTo-Json $opts -Compress
    if ($opts.Count -eq 1) { $batJson = "[$batJson]" }
    $isBosch = @($batList | Where-Object { $_ -match '^\d' }).Count -gt 0   # 41122xxx = Bosch
    $mfs = @(
        @{ namespace = 'specs'; key = 'battery_options'; type = 'json'; value = $batJson },
        @{ namespace = 'specs'; key = 'order_without_battery'; type = 'single_line_text_field'; value = 'No' }
    )
    if ($isBosch) {
        $mfs += @{ namespace = 'specs'; key = 'charger_options'; type = 'json'; value = $chargerJson }
        $mfs += @{ namespace = 'specs'; key = 'order_without_charger'; type = 'single_line_text_field'; value = 'No' }
    }
    foreach ($mf in $mfs) {
        try { $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products/$bikePid/metafields.json" -Headers $h -Body (@{ metafield = $mf } | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 60 } catch { Write-Host "[mf HATA] $bikeSku $($mf.key): $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 250
    }
    $done++
    if ($done % 25 -eq 0) { Write-Host "$done bisiklet islendi" }
}
Write-Host "DONE. metafield yazilan bisiklet: $done | atlanan: $skip"
