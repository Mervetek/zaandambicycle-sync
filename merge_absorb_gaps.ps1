# EKSIK ACCELL KODLARINI EMER (data\accell_gap_codes.csv -> magaza)
# Renk-bazli modele uygun: ayni (model|frametype|renk) urunu varsa BEDEN VARYANTI ekler,
# yoksa yeni urun kurar (metafield: ayni modelin kardes renginden kopya).
# Ayrica accentry_stok.csv'ye ekler (gunluk senkron kapsami) + bike_battery_links'i kardesten cogaltir.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$d = Join-Path $baseDir "data"
function L($m){ Write-Host ((Get-Date -Format 'HH:mm:ss') + " " + $m) }
$cfg = @{}; Get-Content (Join-Path $baseDir "sync.env") | ForEach-Object { if ($_ -cmatch '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$shop = $cfg.SHOPIFY_SHOP; $api = "2024-10"; $loc = [long]$cfg.SHOPIFY_LOCATION
$sb = @{ grant_type="client_credentials"; client_id=$cfg.SHOPIFY_CLIENT_ID; client_secret=$cfg.SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
function REST($method, $path, $body) {
    $uri = "https://$shop/admin/api/$api/$path"
    if ($null -ne $body) {
        $json = $body | ConvertTo-Json -Depth 12
        return Invoke-RestMethod -Method $method -Uri $uri -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
    }
    Invoke-RestMethod -Method $method -Uri $uri -Headers $h -TimeoutSec 120
}
function GQL($q,$v){
    $b = @{ query=$q; variables=$v } | ConvertTo-Json -Depth 14
    Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
}
$osPub  = "gid://shopify/Publication/338868208003"; $posPub = "gid://shopify/Publication/338868240771"

# Accell token (gorseller + ean icin detay gerekebilir)
$ab = @{ username = $cfg.ACCELL_USERNAME; password = $cfg.ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token

$gaps = @(Import-Csv "$d\accell_gap_codes.csv")
L ("eksik kod: " + $gaps.Count)
if (-not $gaps.Count) { exit 0 }

# --- ayristirici: merge_build ile ayni mantigin sadelestirilmisi ---
$ti = (Get-Culture).TextInfo
function StripDiacritics([string]$s) { if(-not $s){return $s}; $n=$s.Normalize([Text.NormalizationForm]::FormD); return -join ($n.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' }) }
function ParseGap($row) {
    $desc = "$($row.description)".Trim()
    foreach ($b in 'Batavus ','Sparta ','Loekie ') { if ($desc.StartsWith($b)) { $desc = $desc.Substring($b.Length) } }
    $cap = "$($row.caption)".Trim()
    $frametype = $null
    if ($cap -cmatch '^(Dames|Heren|Meisjes|Jongens|Uni|Unisex|MEISJES|JONGENS|DAMES|HEREN)\s+(.*)$') { $frametype = $ti.ToTitleCase($Matches[1].ToLowerInvariant()); $rest = $Matches[2] } else { $rest = $cap }
    $size = $null
    if ($rest -cmatch '(?:^|\s|\))[DHG]?(\d{2})\s*$') { $n=[int]$Matches[1]; if ($n -ge 40 -and $n -le 68) { $size = "$n cm" } }
    $color = $null
    if ($rest -cmatch '\(([^)]*(?:Matt|Matte|Gloss|Glans)[^)]*)\)') { $color = $ti.ToTitleCase($Matches[1].ToLowerInvariant().Trim()) }
    elseif ($rest -cmatch '^([A-Za-z ]+?)\s+[A-Z0-9(]') { $c=$Matches[1].Trim(); if ($c) { $color = $ti.ToTitleCase($c.ToLowerInvariant()) } }
    [PSCustomObject]@{ sku=$row.sku; brand=$row.brand; desc=$desc; frametype=$frametype; size=$size; color=$color
        price=[double]("$($row.retail_price)" -replace ',','.'); qty=$(if([int]$row.stock_status -le 2 -and [int]$row.stock -gt 0){[int]$row.stock}elseif([int]$row.stock_status -le 2){5}else{0})
        images=@(("$($row.images)" -split ' \| ') | Where-Object { $_ }) }
}
$parsed = @($gaps | ForEach-Object { ParseGap $_ })

# --- mevcut magaza urunleri: baslik + varyant sku listesi (aktif+taslak) ---
$store = @()
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,title,options,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        $store += @(($resp.Content | ConvertFrom-Json).products)
        $url = $null; if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 300
    }
}
L ("magaza: " + $store.Count + " urun")
$skuOwner = @{}   # sku -> product
foreach ($p in $store) { foreach ($v in @($p.variants)) { $s="$($v.sku)".Trim(); if ($s -and -not $skuOwner.ContainsKey($s)) { $skuOwner[$s] = $p } } }

# --- gap'leri (model|frametype|renk) gruplandir ---
$newRows = @()
foreach ($grp in ($parsed | Group-Object { ($_.brand + '|' + $_.desc + '|' + $_.frametype + '|' + $_.color).ToLowerInvariant() })) {
    $m0 = $grp.Group[0]
    try {
        # hedef urun: ayni modelin AYNI RENK urunu (kardes sku'lardan) var mi?
        # kardes = accentry'de ayni desc'li bilinen kodlar
        $sibSkus = @((Import-Csv "$d\accentry_stok.csv") | Where-Object { ("$($_.description)".Trim() -replace '^(Batavus|Sparta|Loekie) ','') -eq $m0.desc } | ForEach-Object { $_.sku })
        $target = $null
        foreach ($ss in $sibSkus) {
            if ($skuOwner.ContainsKey($ss)) {
                $cand = $skuOwner[$ss]
                if ($cand.title -cmatch [regex]::Escape("$($m0.color)") -and ($null -eq $m0.frametype -or $cand.title -cmatch [regex]::Escape("$($m0.frametype)"))) { $target = $cand; break }
            }
        }
        if ($target) {
            # VARYANT OLARAK EKLE
            foreach ($it in $grp.Group) {
                $sz = if ($it.size) { $it.size } else { 'Standaard' }
                if (@($target.variants | Where-Object { "$($_.option1)" -eq $sz }).Count) { L ("  zaten var: " + $target.title + " / " + $sz); continue }
                $nv = (REST 'Post' ("products/" + $target.id + "/variants.json") @{ variant = @{ option1 = $sz; sku = $it.sku; price = ("{0:0.00}" -f $it.price); inventory_management = 'shopify' } }).variant
                $null = REST 'Post' 'inventory_levels/set.json' @{ location_id = $loc; inventory_item_id = $nv.inventory_item_id; available = $it.qty }
                L ("  VARYANT eklendi: " + $target.title + " + " + $sz + " (" + $it.sku + ")")
                Start-Sleep -Milliseconds 300
            }
        } else {
            # YENI URUN: kardes renkten sablon urun bul (metafield kopyasi icin)
            $tmpl = $null
            foreach ($ss in $sibSkus) { if ($skuOwner.ContainsKey($ss)) { $tmpl = $skuOwner[$ss]; break } }
            $title = (@($m0.brand, $m0.desc, $m0.frametype) | Where-Object { $_ }) -join ' '
            if ($m0.color) { $title += ' - ' + $m0.color }
            $variants = @(); $sorted = @($grp.Group | Sort-Object { if ($_.size -cmatch '(\d+)') { [int]$Matches[1] } else { 999 } })
            foreach ($it in $sorted) { $variants += @{ option1 = $(if ($it.size) { $it.size } else { 'Standaard' }); sku = $it.sku; price = ("{0:0.00}" -f $it.price); inventory_management = 'shopify' } }
            $images = @(); foreach ($s in (@($m0.images) | Select-Object -First 4)) { $images += @{ src = $s } }
            $body = ''; $tags = 'accell, Bisiklet'
            if ($tmpl) { $full = (REST 'Get' ("products/" + $tmpl.id + ".json?fields=body_html,tags,vendor") $null).product; $body = "$($full.body_html)"; $tags = "$($full.tags)" }
            $prod = @{ title=$title; vendor=$m0.brand; body_html=$body; tags=$tags; status='active'; options=@(@{name='Framehoogte'}); variants=$variants; images=$images }
            $np = (REST 'Post' 'products.json' @{ product = $prod }).product
            L ("  YENI URUN: " + $title + " (" + @($np.variants).Count + " varyant)")
            foreach ($nv in @($np.variants)) {
                $src = @($sorted | Where-Object { $_.sku -eq $nv.sku })[0]
                $null = REST 'Post' 'inventory_levels/set.json' @{ location_id = $loc; inventory_item_id = $nv.inventory_item_id; available = $src.qty }
                Start-Sleep -Milliseconds 200
            }
            if ($tmpl) {
                $mfs = @((REST 'Get' ("products/" + $tmpl.id + "/metafields.json?limit=250") $null).metafields)
                $toW = @()
                foreach ($mf in $mfs) {
                    if ($mf.namespace -eq 'specs' -and $mf.key -in @('framesize','frame_size','article_number','size_variants','color_description','basic_color')) { continue }
                    if ($mf.namespace -ne 'specs' -and $mf.namespace -notlike 'shopify--discovery*') { continue }
                    $toW += @{ ownerId = "gid://shopify/Product/" + $np.id; namespace = $mf.namespace; key = $mf.key; type = $mf.type; value = "$($mf.value)" }
                }
                if ($m0.color) { $toW += @{ ownerId = "gid://shopify/Product/" + $np.id; namespace='specs'; key='color_description'; type='single_line_text_field'; value=$m0.color } }
                for ($ci=0; $ci -lt $toW.Count; $ci += 25) {
                    $chunk = @($toW[$ci..([Math]::Min($ci+24,$toW.Count-1))])
                    $null = GQL 'mutation($m:[MetafieldsSetInput!]!){ metafieldsSet(metafields:$m){ userErrors{ message } } }' @{ m = $chunk }
                }
                # aku baglantilarini kardesten cogalt
                $links = @(Import-Csv "$d\bike_battery_links.csv")
                $sibLink = @($links | Where-Object { $sibSkus -contains $_.bike_sku }) | Group-Object bike_sku | Select-Object -First 1
                if ($sibLink) {
                    $add = @()
                    foreach ($it in $grp.Group) { foreach ($lr in $sibLink.Group) { $add += [PSCustomObject]@{ bike_sku=$it.sku; item_sku=$lr.item_sku; tur=$lr.tur } } }
                    ($links + $add) | Sort-Object bike_sku, item_sku, tur -Unique | Export-Csv "$d\bike_battery_links.csv" -NoTypeInformation -Encoding UTF8
                }
            }
            $null = GQL 'mutation($id:ID!,$input:[PublicationInput!]!){ publishablePublish(id:$id, input:$input){ userErrors{ message } } }' @{ id = "gid://shopify/Product/" + $np.id; input = @(@{publicationId=$osPub}, @{publicationId=$posPub}) }
        }
        # stok csv'sine ekle (gunluk senkron kapsami)
        foreach ($it in $grp.Group) { $newRows += @($gaps | Where-Object { $_.sku -eq $it.sku }) }
    } catch { L ("HATA [" + $grp.Name + "]: " + $_.Exception.Message) }
}
if ($newRows.Count) {
    $cur = @(Import-Csv "$d\accentry_stok.csv")
    ($cur + $newRows) | Sort-Object sku -Unique | Export-Csv "$d\accentry_stok.csv" -NoTypeInformation -Encoding UTF8
    L ("accentry_stok.csv guncellendi (+" + $newRows.Count + ")")
}
L "BITTI"
