# Flex aku bisikletlerinin specs.battery_options metafield'ini TAZE tedarikci verisiyle yeniden yazar.
# FIYAT MODELI v2 (patron karari 2026-07-06 aksam, musteri duzeltmesi):
#   Accentry Consumentenprijs BAZ AKUYU (en dusuk kapasite, or. 400Wh) ICERIR.
#   - baz aku: included=true, additional_cost=0 -> temada "Inbegrepen", sepete ayri satir eklenmez
#   - ust kapasiteler: additional_cost = (o akunun Consumentenprijs'i - baz akununki) FARKI;
#     sepete "Accu upgrade (meerprijs)" urununun ACCU-UPG-<fark> varyanti eklenir (cift tahsilat olmasin)
#   - stokta olmayan upgrade LISTEDE KALIR ama available=false + eta ile gri cizilir
#   - sarj aleti bisiklet fiyatina DAHIL DEGIL (charger_options degismedi)
#   Bu model SADECE Accell bisikletleri icin; Cortina (build_cortina_options) tedarikci cevabi bekliyor.
# Kaynaklar: bike_battery_links.csv (dedupe) + Accell canli (articles + batteriesandchargers)
# Idempotent: mevcut metafield hedefle ayniysa yazilmaz. daily_sync.ps1 tarafindan da cagrilir.
param([switch]$Quiet)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
function Log($m) { if (-not $Quiet) { Write-Host $m } else { Write-Output $m } }
$dataDir = Join-Path $PSScriptRoot "data"
$gw = "https://api-gateway.accentry.com"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"

# --- baglantilar (dedupe) ---
$links = Import-Csv "$dataDir/bike_battery_links.csv" | Where-Object { $_.tur -eq 'Batteries' } | Sort-Object bike_sku, item_sku -Unique
$arts = @($links.item_sku | Select-Object -Unique)
Log "baglanti: $($links.Count) | bisiklet: $((@($links.bike_sku | Select-Object -Unique)).Count) | aku makalesi: $($arts.Count)"

# --- Accell canli veri ---
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "$gw/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$fresh = @{}
$q = ($arts | ForEach-Object { "c=$_" }) -join '&'
$ah["fe-request-id"] = [guid]::NewGuid().ToString()
$r = Invoke-RestMethod -Uri "$gw/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
foreach ($a in $arts) {
    $it = $r.result.PSObject.Properties[$a]
    if ($it -and $it.Value -and $it.Value.retail_price.value) {
        $v = $it.Value
        $fresh[$a] = @{ status = "$($v.stock_status)"; retail = [double]$v.retail_price.value; caption = "$($v.caption)"; ean = "$($v.single_ean)".Trim(); week = "$($v.stock_week)"; year = "$($v.stock_year)" }
    }
}
# genel sorguda donmeyenler (tekil satisa kapali, or. 41122222): bagli bir bisiklet uzerinden cek
$missing = @($arts | Where-Object { -not $fresh.ContainsKey($_) })
foreach ($ma in $missing) {
    $bike = ($links | Where-Object { $_.item_sku -eq $ma } | Select-Object -First 1).bike_sku
    if (-not $bike) { continue }
    try {
        $ah["fe-request-id"] = [guid]::NewGuid().ToString()
        $rb = Invoke-RestMethod -Uri "$gw/articles/$bike/batteriesandchargers/?companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30
        $hit = @($rb.result.Batteries) | Where-Object { $_.article_code -eq $ma } | Select-Object -First 1
        if ($hit) { $fresh[$ma] = @{ status = "$($hit.stock_status)"; retail = [double]$hit.retail_price.value; caption = "$($hit.caption)"; ean = "$($hit.single_ean)".Trim(); week = "$($hit.stock_week)"; year = "$($hit.stock_year)" } }
    } catch { }
    Start-Sleep -Milliseconds 300
}
Log "canli veri: $($fresh.Count)/$($arts.Count) makale"
# GUVENLIK FRENI: veri eksikse hicbir sey yazma
if ($fresh.Count -lt [math]::Max(10, [int]($arts.Count * 0.7))) { Log "FREN: canli veri yetersiz ($($fresh.Count)) - cikiliyor, yazma YAPILMADI"; exit 1 }

# --- Shopify token + aku urunlerinden EAN (oncelikli kaynak) ---
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$stok2 = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $stok2 }
$skuEan = @{}; $skuVid = @{}
$url = "https://$shop/admin/api/$api/products.json?limit=250&collection_id=707890479491&fields=id,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
        foreach ($v in $p.variants) {
            $s = "$($v.sku)".Trim(); if (-not $s) { continue }
            $bc = "$($v.barcode)".Trim(); if ($bc) { $skuEan[$s] = $bc }
            if (-not $skuVid.ContainsKey($s)) { $skuVid[$s] = "$($v.id)" }
        }
    }
    $url = $null; if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}

# --- Accu upgrade (meerprijs) urunu: gereken fark varyantlarini garanti et ---
$UPG_PRODUCT_ID = 16073677832579   # "Accu upgrade (meerprijs)" - 2026-07-06'da olusturuldu
$upgProd = (Invoke-RestMethod -Uri "https://$shop/admin/api/$api/products/$UPG_PRODUCT_ID.json" -Headers $h -TimeoutSec 60).product
$upgVid = @{}   # farkTutari(int) -> variant_id
foreach ($v in @($upgProd.variants)) { if ("$($v.sku)" -cmatch '^ACCU-UPG-(\d+)$') { $upgVid[[int]$Matches[1]] = "$($v.id)" } }
function Ensure-UpgVariant([int]$amt) {
    if ($upgVid.ContainsKey($amt)) { return $upgVid[$amt] }
    $b = @{ variant = @{ option1 = "+ $amt"; sku = "ACCU-UPG-$amt"; price = ("{0:0.00}" -f $amt); requires_shipping = $false } } | ConvertTo-Json -Depth 5
    $nv = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products/$UPG_PRODUCT_ID/variants.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60).variant
    $upgVid[$amt] = "$($nv.id)"
    Log "upgrade varyanti olusturuldu: ACCU-UPG-$amt"
    Start-Sleep -Milliseconds 300
    return $upgVid[$amt]
}

# --- hedef JSON'lari kur (v2: baz aku dahil, ust kapasiteler fark ucreti) ---
function CapOf($caption) { if ($caption -cmatch '(\d{3,4})\s*Wh') { return [int]$Matches[1] }; if ($caption -cmatch '(\d{3,4})\s*W\b') { return [int]$Matches[1] }; return 0 }
$target = @{}   # bike_sku -> @{ json; canon }
$akusuz = @(); $vidEksik = @{}
foreach ($grp in ($links | Group-Object bike_sku)) {
    $opts = @()
    foreach ($lnk in $grp.Group) {
        $fa = $fresh["$($lnk.item_sku)"]
        if (-not $fa) { continue }
        $avail = $fa.status -in '1','2'
        $eta = if (-not $avail -and $fa.week -and $fa.week -ne '0') { "$($fa.week)/$($fa.year)" } else { '' }
        $ean = if ($skuEan.ContainsKey($lnk.item_sku)) { $skuEan[$lnk.item_sku] } else { $fa.ean }
        $opts += [PSCustomObject]@{ cap = (CapOf $fa.caption); retail = [math]::Round($fa.retail, 2); ean = $ean; avail = $avail; eta = $eta }
    }
    if (-not $opts.Count) { $akusuz += $grp.Name; continue }
    $opts = @($opts | Sort-Object cap, retail, ean -Unique)
    # BAZ = en dusuk kapasite (Consumentenprijs bunu icerir); digerleri fark oder
    $base = $opts[0]
    $parts = @()
    $canonParts = @()
    foreach ($o in $opts) {
        if ($o.cap -eq $base.cap -and $o.retail -eq $base.retail) {
            # BAZ aku da GERCEK stok durumunu yansitir (onceden available hep true hardcode'du -> stoksuz baz aku
            # "Inbegrepen/available" gorunuyordu; 2026-07-07 musteri: 625Wh bayide st3 ama sitede stokta).
            $parts += '{"capacity_wh":' + $o.cap + ',"additional_cost":0,"barcode":"' + $o.ean + '","included":true,"variant_id":"","available":' + $(if ($o.avail) { 'true' } else { 'false' }) + ',"eta":"' + $o.eta + '"}'
            $canonParts += "$($o.cap)|0|$($o.ean)|INCL|$($o.avail)|$($o.eta)"
        } else {
            $diff = [int][math]::Round($o.retail - $base.retail)
            if ($diff -le 0) { continue }   # baza esit/ucuz ikinci secenek anlamsiz
            $vid = Ensure-UpgVariant $diff
            $parts += '{"capacity_wh":' + $o.cap + ',"additional_cost":' + $diff + ',"barcode":"' + $o.ean + '","included":false,"variant_id":"' + $vid + '","available":' + $(if ($o.avail) { 'true' } else { 'false' }) + ',"eta":"' + $o.eta + '"}'
            $canonParts += "$($o.cap)|$diff|$($o.ean)|$vid|$($o.avail)|$($o.eta)"
        }
    }
    $target[$grp.Name] = @{
        json  = '[' + ($parts -join ',') + ']'
        canon = ($canonParts -join ';')
    }
}
Log "hedef kurulan bisiklet: $($target.Count) | hic secenegi olmayan: $($akusuz.Count) $(if($akusuz.Count){'['+($akusuz -join ',')+']'})"

# --- Shopify urunlerini tara ve gerekenleri yaz ---
$mutation = 'mutation SetMf($metafields: [MetafieldsSetInput!]!) { metafieldsSet(metafields: $metafields) { metafields { id } userErrors { message } } }'
$pending = @(); $logRows = @(); $same = 0; $seen = 0
$cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $gql = '{ "query": "query { products(first: 100, query: \"status:active OR status:draft\"' + $after + ') { pageInfo { hasNextPage endCursor } edges { node { id title variants(first: 50) { edges { node { sku } } } bat: metafield(namespace: \"specs\", key: \"battery_options\") { value } } } } }" }'
    $r2 = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 90
    $pg = $r2.data.products
    foreach ($e in $pg.edges) {
        $n = $e.node
        # birlesik urunlerde (beden+renk tek urun, 2026-07-06) TUM varyant SKU'larina bak; ilki eslesen kazanir
        $sku = $null
        foreach ($ve in @($n.variants.edges)) {
            $s = "$($ve.node.sku)".Trim()
            if ($s -and $target.ContainsKey($s)) { $sku = $s; break }
        }
        if (-not $sku) { continue }
        $seen++
        $t = $target[$sku]
        # mevcutla karsilastir (PS5.1 dizi tuzagina karsi zorla enumerate)
        $curCanon = ''
        if ($n.bat -and "$($n.bat.value)".Trim()) {
            try {
                $cur = @((ConvertFrom-Json -InputObject "$($n.bat.value)") | ForEach-Object { $_ })
                $curCanon = (($cur | Sort-Object capacity_wh, additional_cost, barcode | ForEach-Object {
                    if ($_.included -eq $true) { "$([int]$_.capacity_wh)|0|$("$($_.barcode)".Trim())|INCL|$(if($_.available -eq $false){'False'}else{'True'})|$("$($_.eta)".Trim())" }
                    else { "$([int]$_.capacity_wh)|$([int][math]::Round([double]$_.additional_cost))|$("$($_.barcode)".Trim())|$("$($_.variant_id)".Trim())|$(if($_.available -eq $false){'False'}else{'True'})|$("$($_.eta)".Trim())" }
                }) -join ';')
            } catch { $curCanon = '(parse-hata)' }
        }
        if ($curCanon -eq $t.canon) { $same++; continue }
        $pending += @{ ownerId = $n.id; namespace = 'specs'; key = 'battery_options'; type = 'json'; value = $t.json }
        $logRows += [PSCustomObject]@{ sku = $sku; title = $n.title; eski = "$($n.bat.value)"; yeni = $t.json }
    }
    $cursor = $pg.pageInfo.endCursor
    Start-Sleep -Milliseconds 300
} while ($pg.pageInfo.hasNextPage)
Log "eslesen urun: $seen | zaten dogru: $same | yazilacak: $($pending.Count)"

$ok = 0; $err = 0
for ($i = 0; $i -lt $pending.Count; $i += 25) {
    $batch = @($pending[$i..([Math]::Min($i+24, $pending.Count-1))])
    $body = @{ query = $mutation; variables = @{ metafields = $batch } } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $body -ContentType 'application/json' -TimeoutSec 60
        $ok += @($resp.data.metafieldsSet.metafields).Count
        $ue = @($resp.data.metafieldsSet.userErrors)
        if ($ue.Count) { $err++; Log "[uyari] $($ue[0].message)" }
    } catch { $err++; Log "[HATA] parti $i : $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 600
}
if ($logRows.Count) { $logRows | Export-Csv "$dataDir/aku_rebuild_log.csv" -NoTypeInformation -Encoding utf8 }
Log "DONE. yazilan metafield: $ok | hata partisi: $err | log: data\aku_rebuild_log.csv"
