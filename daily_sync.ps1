# GUNLUK STOK SENKRONU: Kruitbosch + Accell -> Shopify
# Fiyatlara DOKUNMAZ. Sadece stok adedi ve aktif/taslak durumunu gunceller.
# Gorev Zamanlayici tarafindan her gun calistirilir; elle de calistirilabilir.
$ErrorActionPreference = 'Continue'
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$logDir = Join-Path $baseDir "logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("sync_" + (Get-Date -Format "yyyyMMdd_HHmm") + ".log")
function L($m) { $line = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $line; Add-Content $log $line }

# --- konfig ---
$env2 = @{}
# -cmatch sart: Turkce kulturde case-insensitive [A-Z] araligi 'I' harfini eslemiyor (I->i donusumu 'i'siz)
Get-Content (Join-Path $baseDir "sync.env") | ForEach-Object { if ($_ -cmatch '^([A-Z_]+)=(.*)$') { $env2[$Matches[1]] = $Matches[2].Trim() } }
L "senkron basladi"

$supplierQty = @{}   # sku -> hedef adet
$advies = @{}        # sku -> guncel advies (FIYAT SENKRONU 2026-07-07: fiyat=advies, indirim korunmaz - kullanici karari)

# ================= KRUITBOSCH =================
try {
    $pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env2.KRUITBOSCH_USERNAME):$($env2.KRUITBOSCH_PASSWORD)"))
    $kh = @{ Authorization = "Basic $pair" }
    $kp = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=true&ExcludeBlocked=true&IncludeAttributes=false&IncludeAdditionalImages=false&IncludeOriginalImages=false&IncludeInActive=false" -Headers $kh -TimeoutSec 300
    $codes = @($kp.Products | ForEach-Object { "$($_.ProductCode)".Trim() } | Where-Object { $_ })
    foreach ($bp in $kp.Products) { $bc = "$($bp.ProductCode)".Trim(); if ($bc -and $bp.RecommendedSalesPrice) { $advies[$bc] = [double]$bp.RecommendedSalesPrice } }
    L "kruitbosch: $($codes.Count) kod"
    for ($i = 0; $i -lt $codes.Count; $i += 100) {
        $batch = $codes[$i..([Math]::Min($i+99, $codes.Count-1))]
        $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env2.KRUITBOSCH_CUSTOMER)&Products=$($batch -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
        foreach ($s in $r.StocksAndPrices) {
            # GERCEK adet: Kruitbosch StockQuantity = bayi portalindaki gercek stok (ACM22RGM=6, 2026-07-07 musteri hatasi).
            # Availability (Voldoende/Beperkt) sadece stokta/degil KAPISI; adet artik kovadan (1->10 / 2->2) DEGIL StockQuantity'den gelir.
            $av = [int]$s.AvailabilityId
            $sq = 0; if ($null -ne $s.StockQuantity) { $sq = [int]$s.StockQuantity }
            $q = if ($av -in 1, 2) { if ($sq -gt 0) { $sq } elseif ($av -eq 1) { 10 } else { 2 } } else { 0 }
            $supplierQty["$($s.ProductCode)".Trim()] = $q
        }
        Start-Sleep -Milliseconds 400
    }
    L "kruitbosch: $($supplierQty.Count) stok kaydi"
    # C-kod aksesuarlar (Cortina aku/lader urunleri) - bunlar IsBike=true sorgusuna girmez
    try {
        $ccPath = Join-Path $baseDir "data\kruitbosch_ccode_katalog.csv"
        if (Test-Path $ccPath) {
            $cc = @((Import-Csv $ccPath).code | Where-Object { $_ })
            if ($cc.Count) {
                $r2 = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env2.KRUITBOSCH_CUSTOMER)&Products=$($cc -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
                foreach ($s in $r2.StocksAndPrices) {
                    # GERCEK adet: StockQuantity (bayi ile birebir); Availability sadece stokta/degil kapisi
                    $av = [int]$s.AvailabilityId
                    $sq = 0; if ($null -ne $s.StockQuantity) { $sq = [int]$s.StockQuantity }
                    $q = if ($av -in 1, 2) { if ($sq -gt 0) { $sq } elseif ($av -eq 1) { 10 } else { 2 } } else { 0 }
                    $supplierQty["$($s.ProductCode)".Trim()] = $q
                }
                L "kruitbosch aksesuar: $($cc.Count) kod sorgulandi"
            }
        }
    } catch { L "KRUITBOSCH AKSESUAR HATA: $($_.Exception.Message)" }
} catch { L "KRUITBOSCH HATA: $($_.Exception.Message)" }

# --- magaza SKU listesi: Accell kapsamini MAGAZA-GUDUMLU yap (2026-07-07) ---
# Onceden accSkus statik CSV'den geliyordu -> sonradan eklenen urunler senkron disi kaliyordu (or. RENL1009, BE501xxx bayat stok).
$storeSkus = @()
try {
    $sbEarly = @{ grant_type = "client_credentials"; client_id = $env2.SHOPIFY_CLIENT_ID; client_secret = $env2.SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
    $tokEarly = (Invoke-RestMethod -Method Post -Uri "https://$($env2.SHOPIFY_SHOP)/admin/oauth/access_token" -Body $sbEarly -ContentType 'application/json' -TimeoutSec 30).access_token
    $shEarly = @{ "X-Shopify-Access-Token" = $tokEarly }
    foreach ($st in 'active', 'draft') {
        $url = "https://$($env2.SHOPIFY_SHOP)/admin/api/2024-10/products.json?limit=250&status=$st&fields=variants"
        while ($url) {
            $resp = Invoke-WebRequest -Uri $url -Headers $shEarly -UseBasicParsing -TimeoutSec 60
            foreach ($p in (($resp.Content | ConvertFrom-Json).products)) { foreach ($v in $p.variants) { $s = "$($v.sku)".Trim(); if ($s) { $storeSkus += $s } } }
            $url = $null
            if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
            Start-Sleep -Milliseconds 300
        }
    }
    $storeSkus = @($storeSkus | Select-Object -Unique)
    L "magaza SKU (Accell kapsam): $($storeSkus.Count)"
} catch { L "MAGAZA SKU HATA: $($_.Exception.Message)" }

# ================= ACCELL =================
try {
    $ab = @{ username = $env2.ACCELL_USERNAME; password = $env2.ACCELL_PASSWORD } | ConvertTo-Json
    $atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
    $ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
    $accSkus = @()
    foreach ($f in @("data\accentry_stok.csv", "data\battery_catalog.csv")) {
        $p = Join-Path $baseDir $f
        if (Test-Path $p) { $accSkus += (Import-Csv $p | ForEach-Object { "$($_.sku)".Trim() }) }
    }
    $accSkus += @($storeSkus | Where-Object { -not $supplierQty.ContainsKey($_) })   # magaza-gudumlu kapsam (2026-07-07)
    $accSkus = @($accSkus | Where-Object { $_ } | Select-Object -Unique)
    L "accell: $($accSkus.Count) kod sorgulanacak"
    $found = 0
    for ($i = 0; $i -lt $accSkus.Count; $i += 20) {
        $batch = $accSkus[$i..([Math]::Min($i+19, $accSkus.Count-1))]
        $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
        try {
            $ah["fe-request-id"] = [guid]::NewGuid().ToString()
            $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
            foreach ($code in $batch) {
                $a = $r.result.PSObject.Properties[$code]
                if ($a -and $a.Value) {
                    $v = $a.Value
                    # SADECE stock_status 1-2 gercek raf stogudur; st3 = yoldaki/rezerve adet (satista "stokta" gosterilemez, bkz. musteri sikayeti 2026-07-05)
                    $qty = 0
                    if ([int]$v.stock_status -le 2) { $qty = if ([int]$v.stock -gt 0) { [int]$v.stock } else { 5 } }
                    $supplierQty[$code] = $qty
                    if ($v.retail_price.value) { $advies[$code] = [double]$v.retail_price.value }
                    $found++
                }
            }
        } catch { L "accell parti hatasi: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 350
    }
    L "accell: $found stok kaydi"
} catch { L "ACCELL HATA: $($_.Exception.Message)" }

if ($supplierQty.Count -lt 100) { L "GUVENLIK: tedarikci verisi cok az ($($supplierQty.Count)) - magazaya dokunulmuyor. Cikis."; exit 1 }

# ================= SHOPIFY =================
try {
    $sb = @{ grant_type = "client_credentials"; client_id = $env2.SHOPIFY_CLIENT_ID; client_secret = $env2.SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
    $stok = (Invoke-RestMethod -Method Post -Uri "https://$($env2.SHOPIFY_SHOP)/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
    $sh = @{ "X-Shopify-Access-Token" = $stok }
    $api = "2024-10"; $shop = $env2.SHOPIFY_SHOP; $loc = $env2.SHOPIFY_LOCATION

    # magazadaki tum urunler - VARYANT SEVIYESINDE (birlesik beden+renk urunleri 2026-07-06)
    $store = @()
    foreach ($st in 'active','draft') {
        $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,status,tags,variants"
        while ($url) {
            $resp = Invoke-WebRequest -Uri $url -Headers $sh -UseBasicParsing -TimeoutSec 60
            foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
                $vlist = @($p.variants | ForEach-Object { [PSCustomObject]@{ id = $_.id; sku = "$($_.sku)".Trim(); qty = $_.inventory_quantity; inv_item = $_.inventory_item_id; price = [double]$_.price } })
                $store += [PSCustomObject]@{ product_id = $p.id; status = $p.status; tags = "$($p.tags)"; variants = $vlist }
            }
            $url = $null
            if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
            Start-Sleep -Milliseconds 400
        }
    }
    L "shopify: $($store.Count) urun / $((@($store | ForEach-Object { $_.variants })).Count) varyant tarandi"

    $qtyChanged = 0; $activated = 0; $drafted = 0; $skipped = 0; $priceChanged = 0
    foreach ($item in $store) {
        $known = @($item.variants | Where-Object { $_.sku -and $supplierQty.ContainsKey($_.sku) })
        if (-not $known.Count) { $skipped++; continue }
        try {
            foreach ($v in $known) {
                $target = [int]$supplierQty[$v.sku]
                if ([int]$v.qty -ne $target) {
                    $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/inventory_levels/set.json" -Headers $sh -Body (@{ location_id = [long]$loc; inventory_item_id = $v.inv_item; available = $target } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
                    $qtyChanged++
                    Start-Sleep -Milliseconds 300
                }
                # FIYAT SENKRONU (2026-07-07): bisiklet fiyati = guncel advies (indirim korunmaz - kullanici karari).
                # Aksesuar (Accu's en Laders) HARIC; %60'tan buyuk sapma = veri suphesi -> atla+logla (fiyat guvenlik freni).
                if ("$($item.tags)" -notmatch "Accu's en Laders" -and $advies.ContainsKey($v.sku) -and $advies[$v.sku] -gt 0) {
                    $newP = [math]::Round([double]$advies[$v.sku], 2)
                    if ([math]::Abs($newP - $v.price) -gt 0.01) {
                        if ($v.price -gt 0 -and ([math]::Abs($newP - $v.price) / $v.price) -gt 0.6) {
                            L "FIYAT-ATLA (>%60 sapma, veri suphesi): $($v.sku) $($v.price)->$newP"
                        } else {
                            $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/variants/$($v.id).json" -Headers $sh -Body (@{ variant = @{ id = [long]$v.id; price = ("{0:0.00}" -f $newP) } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
                            $priceChanged++
                            Start-Sleep -Milliseconds 300
                        }
                    }
                }
            }
            # POLITIKA (2026-07-05): stoksuz urunler de vitrinde kalir (qty=0, satin alinamaz); taslak sadece fiyatsizlar
            $wantStatus = if (@($item.variants | Where-Object { $_.price -gt 0 }).Count -gt 0) { 'active' } else { 'draft' }
            if ($item.status -ne $wantStatus) {
                $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($item.product_id).json" -Headers $sh -Body (@{ product = @{ id = $item.product_id; status = $wantStatus } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
                if ($wantStatus -eq 'active') {
                    $activated++
                    # status=active tek basina KANALA YAYINLAMAZ - Online Store + POS'a publishablePublish sart
                    # (2026-07-06 vakasi: 492 aktif urun vitrinde 404 idi). Zaten yayinliysa no-op.
                    $pubMut = 'mutation($id:ID!,$input:[PublicationInput!]!){ publishablePublish(id:$id, input:$input){ userErrors{ message } } }'
                    $pubBody = @{ query = $pubMut; variables = @{ id = "gid://shopify/Product/$($item.product_id)"; input = @(
                        @{ publicationId = "gid://shopify/Publication/338868208003" }   # Online Store
                        @{ publicationId = "gid://shopify/Publication/338868240771" }   # Point of Sale
                    ) } } | ConvertTo-Json -Depth 8
                    $pubR = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $sh -Body ([Text.Encoding]::UTF8.GetBytes($pubBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
                    $pubUe = @($pubR.data.publishablePublish.userErrors)
                    if ($pubUe.Count) { L "yayin hatasi $($item.product_id): $($pubUe[0].message)" }
                } else { $drafted++ }
                Start-Sleep -Milliseconds 300
            }
        } catch { L "urun hatasi $($item.product_id): $($_.Exception.Message)" }
    }
    L "SONUC: adet degisen $qtyChanged | fiyat degisen $priceChanged | satisa acilan $activated | satistan cekilen $drafted | veri disi $skipped"
} catch { L "SHOPIFY HATA: $($_.Exception.Message)" }

# ================= AKU SECENEKLERI (specs.battery_options) =================
# Flex bisikletlerin aku seceneklerini taze tedarikci stok/fiyatiyla tazeler (musteri sikayeti duzeltmesi 2026-07-06).
# YENI Flex bisikletlerin aku/sarj baglantilarini kesfet (statik CSV kapsam bosluguna karsi, 2026-07-07).
# battery_options'i olmayan "Flex accu" urunleri bulup Accell'den link cikarir + charger kopyalar -> rebuild sonra kurar.
try {
    & (Join-Path $baseDir "discover_flex_links.ps1") | ForEach-Object { L "flex-kesif: $_" }
} catch { L "FLEX KESIF HATA: $($_.Exception.Message)" }
# Kendi guvenlik freni var: canli veri eksikse hicbir sey yazmaz. Idempotent: degisiklik yoksa yazmaz.
try {
    & (Join-Path $baseDir "rebuild_battery_options.ps1") -Quiet | ForEach-Object { L "aku: $_" }
} catch { L "AKU SECENEK HATA: $($_.Exception.Message)" }
# Cortina aku/lader secenekleri (Kruitbosch C-kodlari, kati model)
try {
    & (Join-Path $baseDir "build_cortina_options.ps1") -Quiet | ForEach-Object { L "cortina: $_" }
} catch { L "CORTINA SECENEK HATA: $($_.Exception.Message)" }
L "senkron bitti"
