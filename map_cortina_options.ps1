# SALT OKUNUR KESIF (adim 2): Cortina aku/lader secenekleri icin veri toplar
# Girdi: data\cortina_battery_map.csv (eski site kesfi: bisiklet SKU -> C-kod aku/lader setleri)
# Cikti: data\cortina_secici_plan.csv + data\kruitbosch_ccode_katalog.csv (fiyat/stok/EAN)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$kUser = $env:KRUITBOSCH_USERNAME; $kPass = $env:KRUITBOSCH_PASSWORD
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${kUser}:${kPass}"))
$kh = @{ Authorization = "Basic $pair" }

$map = Import-Csv "$dataDir\cortina_battery_map.csv"
$ccodes = @($map.item_skus -split '\|' | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
Write-Host "eslesme satiri: $($map.Count) | benzersiz C-kod: $($ccodes.Count) [$($ccodes -join ', ')]"

# --- 1) Kruitbosch katalog verisi (ad, advies, EAN) - once IsBike=false dene, olmazsa genel ---
$katalog = @{}
try {
    $kp = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=false&ExcludeBlocked=false&IncludeAttributes=true&IncludeAdditionalImages=false&IncludeOriginalImages=false&IncludeInActive=true" -Headers $kh -TimeoutSec 300
    foreach ($p in @($kp.Products)) {
        $c = "$($p.ProductCode)".Trim()
        if ($c -in $ccodes) {
            $attrs = @{}
            foreach ($a in @($p.Attributes)) { $attrs[$a.Attribute] = "$($a.AttributeValue)" }
            $katalog[$c] = [PSCustomObject]@{
                code = $c; ad = "$($p.Description)"; ean = "$($p.EANCode)".Trim()
                advies = $p.RecommendedSalesPrice
                kapasite = $(if ($attrs.ContainsKey('Accu capaciteit')) { $attrs['Accu capaciteit'] } elseif ("$($p.Description)" -cmatch '(\d{3,4})\s*Wh') { $Matches[1] } else { '' })
            }
        }
    }
    Write-Host "katalog (IsBike=false): $($katalog.Count)/$($ccodes.Count) bulundu"
} catch { Write-Host "IsBike=false HATA: $($_.Exception.Message)" }

# --- 2) Stok + fiyat (StocksAndPrices C-kodlarla dogrudan calisir) ---
$stok = @{}
try {
    $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$kUser&Products=$($ccodes -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 120
    foreach ($s in @($r.StocksAndPrices)) {
        $stok["$($s.ProductCode)".Trim()] = [PSCustomObject]@{
            avail = [int]$s.AvailabilityId; nett = $s.PriceNett; gross = $s.PriceGross; tarih = "$($s.DateAvailable)"
        }
    }
    Write-Host "stok kaydi: $($stok.Count)/$($ccodes.Count)"
} catch { Write-Host "StocksAndPrices HATA: $($_.Exception.Message)" }

# --- 3) C-kod katalog raporu ---
$katRows = foreach ($c in $ccodes) {
    $k = $katalog[$c]; $s = $stok[$c]
    [PSCustomObject]@{
        code = $c
        ad = $(if ($k) { $k.ad } else { '' })
        kapasite_wh = $(if ($k) { $k.kapasite } else { '' })
        ean = $(if ($k) { $k.ean } else { '' })
        advies = $(if ($k) { $k.advies } else { '' })
        availability = $(if ($s) { $s.avail } else { '' })
        durum = $(if ($s) { switch ($s.avail) { 1 {'Voldoende'} 2 {'Beperkt'} 3 {'Niet leverbaar'} default {"($($s.avail))"} } } else { 'VERI YOK' })
        alis_nett = $(if ($s) { $s.nett } else { '' })
    }
}
$katRows | Export-Csv "$dataDir\kruitbosch_ccode_katalog.csv" -NoTypeInformation -Encoding utf8
Write-Host "--- C-kod katalogu ---"
$katRows | Format-Table code, kapasite_wh, advies, durum, ean -AutoSize | Out-String -Width 160 | Write-Host

# --- 4) yeni magaza eslesmesi: eski site bike_sku'lari Shopify'da var mi ---
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
$storeSkus = @{}
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,title,status,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            $s2 = "$($p.variants[0].sku)".Trim()
            if ($s2 -and -not $storeSkus.ContainsKey($s2)) { $storeSkus[$s2] = [PSCustomObject]@{ id = $p.id; title = $p.title; status = $p.status } }
        }
        $url = $null; if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 350
    }
}
$plan = foreach ($grp in ($map | Group-Object bike_sku)) {
    $sku = $grp.Name
    $sp = $storeSkus[$sku]
    $accu = @($grp.Group | Where-Object { $_.tur -eq 'accu' } | Select-Object -First 1)
    $lader = @($grp.Group | Where-Object { $_.tur -eq 'lader' } | Select-Object -First 1)
    [PSCustomObject]@{
        bike_sku = $sku
        bike_ad = $grp.Group[0].bike_name
        magazada = $(if ($sp) { $sp.status } else { 'YOK' })
        product_id = $(if ($sp) { $sp.id } else { '' })
        accu_seti = $(if ($accu) { $accu[0].item_skus } else { '' })
        lader_seti = $(if ($lader) { $lader[0].item_skus } else { '' })
    }
}
$plan | Export-Csv "$dataDir\cortina_secici_plan.csv" -NoTypeInformation -Encoding utf8
$var = @($plan | Where-Object { $_.magazada -ne 'YOK' })
Write-Host "PLAN: $($plan.Count) eski-site bisikleti | yeni magazada bulunan: $($var.Count) | bulunamayan: $($plan.Count - $var.Count)"
Write-Host "DONE. plan: data\cortina_secici_plan.csv"
