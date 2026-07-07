# BEDEN+RENK BIRLESTIRME - Adim 3: birlesik urunleri OLUSTURUR (data\merge_plan.json'dan)
# Idempotent: data\merge_done.csv done-log (key -> yeni urun id); yarim kalirsa yeniden calistirilabilir.
# Eski urunlere DOKUNMAZ (arsivleme ayri adim: merge_archive_old.ps1)
param([int]$Limit = 0)   # 0 = tumu; pilot icin -Limit 1
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$d = Join-Path $baseDir "data"
$doneFile = "$d\merge_done.csv"
$logFile = Join-Path $baseDir ("logs\merge_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
function L($m){ $line = (Get-Date -Format 'HH:mm:ss') + " " + $m; Write-Host $line; Add-Content -Path $logFile -Value $line -Encoding UTF8 }

$cfg = @{}; Get-Content (Join-Path $baseDir "sync.env") | ForEach-Object { if ($_ -cmatch '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$shop = $cfg.SHOPIFY_SHOP; $api = "2024-10"; $loc = [long]$cfg.SHOPIFY_LOCATION
function NewToken {
    $sb = @{ grant_type="client_credentials"; client_id=$cfg.SHOPIFY_CLIENT_ID; client_secret=$cfg.SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
    (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
}
$script:h = @{ "X-Shopify-Access-Token" = (NewToken) }
function REST($method, $path, $body) {
    $uri = "https://$shop/admin/api/$api/$path"
    for ($try=1; $try -le 4; $try++) {
        try {
            if ($null -ne $body) {
                $json = $body | ConvertTo-Json -Depth 12
                return Invoke-RestMethod -Method $method -Uri $uri -Headers $script:h -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
            } else {
                return Invoke-RestMethod -Method $method -Uri $uri -Headers $script:h -TimeoutSec 120
            }
        } catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 429) { Start-Sleep -Seconds (2*$try); continue }
            if ($code -eq 401) { $script:h = @{ "X-Shopify-Access-Token" = (NewToken) }; continue }
            throw
        }
    }
    throw "REST $method $path : yeniden denemeler tukendi"
}
function GQL($q,$v){
    $b = @{ query=$q; variables=$v } | ConvertTo-Json -Depth 14
    Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $script:h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
}
$osPub  = "gid://shopify/Publication/338868208003"
$posPub = "gid://shopify/Publication/338868240771"

$plan = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText("$d\merge_plan.json"))) | ForEach-Object { $_ })
$done = @{}
if (Test-Path $doneFile) { Import-Csv $doneFile | ForEach-Object { $done[$_.key] = $_.new_id } }
L ("Plan: " + $plan.Count + " grup; tamamlanmis: " + $done.Count)

$gi = 0
foreach ($g in $plan) {
    $gi++
    if ($done.ContainsKey($g.key)) { continue }
    try {
        $members = @($g.members | ForEach-Object { $_ } | Where-Object { [double]$_.price -gt 0 })
        if ($members.Count -lt 1) { L ("ATLA (fiyatli uye yok): " + $g.title); continue }
        $sizes  = @($members | ForEach-Object { $_.size }  | ForEach-Object { if ($_) { $_ } else { 'Standaard' } } | Select-Object -Unique)
        $colors = @($members | ForEach-Object { $_.color } | Select-Object -Unique)
        # KULLANICI KARARI (2026-07-06 aksam): renkler ayri urun -> planda gruplar renk-ici; sadece Framehoogte secenegi
        $useSize  = ($sizes.Count -gt 1) -or ($colors.Count -eq 1)
        $useColor = ($colors.Count -gt 1)

        # --- varyantlar ---
        $variants = @()
        foreach ($m in $members) {
            $sz = if ($m.size) { $m.size } else { 'Standaard' }
            $v = @{ sku = $m.sku; price = ("{0:0.00}" -f [double]$m.price); inventory_management = 'shopify' }
            if ($m.barcode) { $v.barcode = $m.barcode }
            if ($useSize -and $useColor) { $v.option1 = $sz; $v.option2 = $m.color }
            elseif ($useSize) { $v.option1 = $sz }
            else { $v.option1 = $m.color }
            $variants += $v
        }
        $options = @()
        if ($useSize)  { $options += @{ name = 'Framehoogte' } }
        if ($useColor) { $options += @{ name = 'Kleur' } }

        # --- gorseller: her renk icin en cok gorselli uyeden ilk 3 (alt = kleur:<renk>) ---
        $images = @()
        foreach ($c in $colors) {
            $cm = @($members | Where-Object { $_.color -eq $c }) | Sort-Object @{e={@($_.images).Count};Descending=$true} | Select-Object -First 1
            $srcs = @($cm.images) | Select-Object -First 3
            $first = $true
            foreach ($s in $srcs) {
                $img = @{ src = $s }
                if ($first) { $img.alt = "kleur:" + $c; $first = $false } else { $img.alt = "extra:" + $c }
                $images += $img
            }
        }

        # --- gövde: en uzun body'li uyeden; Framehoogte satiri tabloda yaniltici -> cikar ---
        $rep = $members | Sort-Object @{e={ ("$($_.body)").Length };Descending=$true} | Select-Object -First 1
        $body = "$($rep.body)"
        $body = [regex]::Replace($body, '(?s)<tr[^>]*>(?:(?!</tr>).)*?Framehoogte(?:(?!</tr>).)*?</tr>', '')

        # --- etiket birligi ---
        $tagSet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($m in $members) { foreach ($t in @($m.tags)) { $null = $tagSet.Add("$t".Trim()) } }
        $tags = ($tagSet | Where-Object { $_ }) -join ', '

        # --- urun olustur ---
        $prod = @{ title = $g.title; vendor = $g.vendor; body_html = $body; tags = $tags; status = 'active'
                   options = $options; variants = $variants; images = $images }
        $resp = REST 'Post' 'products.json' @{ product = $prod }
        $np = $resp.product
        L ("[" + $gi + "/" + $plan.Count + "] OLUSTU: " + $g.title + " (id " + $np.id + ", " + @($np.variants).Count + " varyant)")

        # --- renk gorselini varyantlara bagla ---
        if ($useColor) {
            $imgByColor = @{}
            foreach ($im in @($np.images)) { if ("$($im.alt)" -like 'kleur:*') { $imgByColor[("$($im.alt)").Substring(6)] = $im.id } }
            foreach ($nv in @($np.variants)) {
                $c = if ($useSize) { $nv.option2 } else { $nv.option1 }
                if ($c -and $imgByColor.ContainsKey($c)) {
                    $null = REST 'Put' ("variants/" + $nv.id + ".json") @{ variant = @{ id = $nv.id; image_id = $imgByColor[$c] } }
                    Start-Sleep -Milliseconds 250
                }
            }
        }

        # --- stok adetleri ---
        $qtyBySku = @{}; foreach ($m in $members) { $qtyBySku[$m.sku] = [int]$m.qty }
        foreach ($nv in @($np.variants)) {
            $q = if ($qtyBySku.ContainsKey($nv.sku)) { $qtyBySku[$nv.sku] } else { 0 }
            $null = REST 'Post' 'inventory_levels/set.json' @{ location_id = $loc; inventory_item_id = $nv.inventory_item_id; available = $q }
            Start-Sleep -Milliseconds 250
        }

        # --- metafield tasima: uyeler arasinda specs'i EN ZENGIN olandan (duplike kopyalar zayif olabiliyor) ---
        $mfs = @(); $bestSpecCount = -1
        foreach ($cand in ($members | Sort-Object @{e={ ("$($_.body)").Length };Descending=$true})) {
            $candId = ($cand.gid -replace '.*/','')
            $candMfs = @((REST 'Get' ("products/" + $candId + "/metafields.json?limit=250") $null).metafields)
            $sc = @($candMfs | Where-Object { $_.namespace -eq 'specs' }).Count
            if ($sc -gt $bestSpecCount) { $bestSpecCount = $sc; $mfs = $candMfs }
            if ($sc -ge 15) { break }
            Start-Sleep -Milliseconds 200
        }
        $skipKeys = @('framesize','frame_size','article_number','size_variants')
        $toWrite = @()
        foreach ($mf in $mfs) {
            if ($mf.namespace -eq 'specs' -and $skipKeys -contains $mf.key) { continue }
            if ($mf.namespace -ne 'specs' -and $mf.namespace -notlike 'shopify--discovery*') { continue }
            $toWrite += @{ ownerId = "gid://shopify/Product/" + $np.id; namespace = $mf.namespace; key = $mf.key; type = $mf.type; value = "$($mf.value)" }
        }
        # battery/charger: grup icinde en sik dolu deger
        foreach ($fld in @(@{k='battery_options';p='battOpts'}, @{k='charger_options';p='chgOpts'})) {
            $vals = @($members | ForEach-Object { $_.($fld.p) } | Where-Object { $_ }) | Group-Object | Sort-Object Count -Descending
            if ($vals) {
                $toWrite = @($toWrite | Where-Object { -not ($_.namespace -eq 'specs' -and $_.key -eq $fld.k) })
                $toWrite += @{ ownerId = "gid://shopify/Product/" + $np.id; namespace = 'specs'; key = $fld.k; type = 'json'; value = $vals[0].Name }
            }
        }
        for ($ci = 0; $ci -lt $toWrite.Count; $ci += 25) {
            $chunk = @($toWrite[$ci..([Math]::Min($ci+24, $toWrite.Count-1))])
            $r = GQL 'mutation($m:[MetafieldsSetInput!]!){ metafieldsSet(metafields:$m){ userErrors{ field message } } }' @{ m = $chunk }
            $ue = @($r.data.metafieldsSet.userErrors)
            if ($ue.Count) { L ("  metafield uyari: " + $ue[0].message) }
            Start-Sleep -Milliseconds 300
        }

        # --- kanallara yayinla (status duzeltmesi sondaki toplu geciste - Flow gorselsiz aninda draft'a cevirebiliyor) ---
        $r = GQL 'mutation($id:ID!,$input:[PublicationInput!]!){ publishablePublish(id:$id, input:$input){ userErrors{ message } } }' @{ id = "gid://shopify/Product/" + $np.id; input = @(@{publicationId=$osPub}, @{publicationId=$posPub}) }
        $ue = @($r.data.publishablePublish.userErrors)
        if ($ue.Count) { L ("  yayin uyari: " + $ue[0].message) }

        # --- done-log ---
        $oldGids = (@($g.members | ForEach-Object { $_.gid })) -join ';'
        if (-not (Test-Path $doneFile)) { 'key,new_id,old_gids' | Set-Content $doneFile -Encoding UTF8 }
        ('"' + $g.key.Replace('"','""') + '",' + $np.id + ',"' + $oldGids + '"') | Add-Content $doneFile -Encoding UTF8
        $done[$g.key] = $np.id
        if ($Limit -gt 0 -and $done.Count -ge $Limit) { L "Limit doldu, cikiliyor."; break }
        Start-Sleep -Milliseconds 500
    } catch {
        L ("HATA [" + $g.title + "]: " + $_.Exception.Message)
        Start-Sleep -Seconds 2
    }
}
L ("Olusturma bitti: " + $done.Count + "/" + $plan.Count + " grup")

# ================= SON GECIS: Flow'un draft'a cevirdiklerini aktive et + yeniden yayinla =================
# (gorseller asenkron indigi icin Flow "gorselsiz->taslak" kurali olusturma aninda tetiklenebiliyor)
L "Son gecis: status/yayin duzeltmesi..."
Start-Sleep -Seconds 20   # son urunlerin gorselleri insin
$fixedStatus = 0
foreach ($kv in $done.GetEnumerator()) {
    try {
        $p = (REST 'Get' ("products/" + $kv.Value + ".json?fields=id,status,images") $null).product
        if ($p.status -ne 'active' -and @($p.images).Count -gt 0) {
            $null = REST 'Put' ("products/" + $p.id + ".json") @{ product = @{ id = $p.id; status = 'active' } }
            $fixedStatus++
        }
        $r = GQL 'mutation($id:ID!,$input:[PublicationInput!]!){ publishablePublish(id:$id, input:$input){ userErrors{ message } } }' @{ id = "gid://shopify/Product/" + $kv.Value; input = @(@{publicationId=$osPub}, @{publicationId=$posPub}) }
        Start-Sleep -Milliseconds 300
    } catch { L ("son gecis hata (" + $kv.Value + "): " + $_.Exception.Message) }
}
L ("BITTI: " + $done.Count + "/" + $plan.Count + " grup tamam; status duzeltilen: " + $fixedStatus)
