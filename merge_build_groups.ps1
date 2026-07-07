# BEDEN+RENK BIRLESTIRME - Adim 2: gruplama plani (salt okunur, magazaya yazmaz)
# Kaynaklar: data\merge_source_catalog.json (Shopify durumu)
#            data\kruitbosch_products_attrs.json (KB attrleri)
#            data\accentry_stok.csv (Accell caption/model)
# Cikti:  data\merge_plan.json + data\merge_plan_review.csv + ekrana ozet
$ErrorActionPreference = 'Stop'
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$d = Join-Path $baseDir "data"

$catalog = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText("$d\merge_source_catalog.json"))) | ForEach-Object { $_ })
$kbArr = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText("$d\kruitbosch_products_attrs.json"))) | ForEach-Object { $_ })
$acc = Import-Csv "$d\accentry_stok.csv"
Write-Host ("Katalog: " + $catalog.Count + " | KB: " + $kbArr.Count + " | Accell: " + $acc.Count)

# ---- KB attr sozlugu: sku -> @{attr=deger} ----
$kbAttr = @{}
foreach ($p in $kbArr) {
    $m = @{}
    foreach ($a in @($p.Attributes | ForEach-Object { $_ })) { $m[$a.Attribute] = "$($a.AttributeValue)".Trim() }
    $m['__desc'] = $p.Description
    $kbAttr[$p.ProductCode] = $m
}
# C-kod katalogu da KB'dir ama aksesuar - dokunmuyoruz.

# ---- Accell caption cozumleme ----
# caption: "<Doelgroep> [renk sozcukleri] <YAPISAL KOD BLOGU>[size]"  (size = sondaki 2 hane)
function Parse-AccCaption([string]$cap, [string]$anchorWord) {
    $cap = "$cap".Trim()
    $res = @{ frametype=$null; color=$null; struct=$null; size=$null }
    if ($cap -cmatch '^(Dames|Heren|Meisjes|Jongens|Uni|Unisex|MEISJES|JONGENS|DAMES|HEREN)\s+(.*)$') {
        $res.frametype = (Get-Culture).TextInfo.ToTitleCase($Matches[1].ToLowerInvariant())
        $rest = $Matches[2]
    } else { $rest = $cap }
    # sondaki beden: 2 hane (40-68 frame cm) ya da harf beden (S/M/L/XL - Sparta Senz vb.)
    if ($rest -cmatch '^(.*?)(\d{2})\s*$') {
        $n = [int]$Matches[2]
        if ($n -ge 40 -and $n -le 68) { $res.size = "$n cm"; $rest = $Matches[1].Trim() }
    }
    elseif ($rest -cmatch '^(.*?[)\w])\s+(S|M|L|XL)\s*$') {
        $res.size = $Matches[2]; $rest = $Matches[1].Trim()
    }
    # yapisal kodun basi: TERCIHEN desc'in ilk kelimesiyle eslesen token (renkler de BUYUK yazilabiliyor,
    # ornek: "Dames SMOKINGBLACK MATT ALTURA CP L ..." - SMOKINGBLACK renk, ALTURA model)
    $tokens = $rest -split '\s+'
    $ci = -1
    if ($anchorWord) {
        for ($i=0; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i].ToLowerInvariant() -eq $anchorWord.ToLowerInvariant()) { $ci = $i; break }
        }
    }
    if ($ci -lt 0) {
        for ($i=0; $i -lt $tokens.Count; $i++) {
            $t = $tokens[$i]
            if ($t -cmatch '^[A-Z0-9()./\-]{2,}$' -and $t -cmatch '[A-Z]{2}') { $ci = $i; break }
        }
    }
    if ($ci -ge 0) {
        $res.color = (($tokens[0..([Math]::Max(0,$ci-1))] | Where-Object { $ci -gt 0 }) -join ' ').Trim()
        $res.struct = ($tokens[$ci..($tokens.Count-1)] -join ' ').Trim()
    } else { $res.color = $rest }
    if (-not $res.color) { $res.color = $null }
    return $res
}
$accBySku = @{}
foreach ($a in $acc) { $accBySku[$a.sku] = $a }

# ---- gruplari kur ----
$ti = (Get-Culture).TextInfo
function TitleCaseColor([string]$c) { if (-not $c) { return $null }; return $ti.ToTitleCase($c.ToLowerInvariant()) }
function StripDiacritics([string]$s) {
    if (-not $s) { return $s }
    $n = $s.Normalize([Text.NormalizationForm]::FormD)
    return -join ($n.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}
# Renk sozcuklerini tek tek temizler; her harfe + niceleyicisi -> "Jett"~"Jet" typo'su da yakalanir.
# Sinir: bosluk/parantez (tire DEGIL -> "E-Blau" icindeki "Blau" korunur).
function RemoveColorWords([string]$text, [string]$color) {
    if (-not $text -or -not $color) { return $text }
    foreach ($w in ((StripDiacritics $color) -split '\s+')) {
        if ($w.Length -lt 3) { continue }
        $pat = '(?i)(?<=^|[\s(])' + ((($w.ToCharArray()) | ForEach-Object { [regex]::Escape("$_") + '+' }) -join '') + '(?=$|[\s)])'
        $text = [regex]::Replace($text, $pat, ' ')
    }
    $text = $text -creplace '\(\s*\)', ' '
    return (($text -creplace '\s+', ' ').Trim())
}

$items = @()      # her aktif bisiklet icin cozumlenmis kayit
$skipped = @()
foreach ($p in $catalog) {
    $tags = @($p.tags)
    if ($tags -contains "Accu's en Laders") { continue }
    $v = $p.variants.nodes[0]
    $sku = "$($v.sku)".Trim()
    $rec = [ordered]@{
        gid=$p.id; title=$p.title; handle=$p.handle; status=$p.status; vendor=$p.vendor
        sku=$sku; barcode=$v.barcode; price=[double]$v.price; qty=[int]$v.inventoryQuantity
        variantGid=$v.id; invItem=$v.inventoryItem.id
        images=@(@($p.media.nodes) | ForEach-Object { $_.image.url } | Where-Object { $_ })
        tags=$tags; body=$p.descriptionHtml
        battOpts = $(if ($p.battOpts) { $p.battOpts.value } else { $null })
        chgOpts  = $(if ($p.chgOpts)  { $p.chgOpts.value }  else { $null })
        key=$null; size=$null; color=$null; kaynak=$null; groupTitle=$null; sizeOrder=999; supplierBrand=$null
    }
    if ($kbAttr.ContainsKey($sku)) {
        $a = $kbAttr[$sku]
        $rec.kaynak = 'KB'
        $doel = $a['Doelgroep']; $frmodel = $a['Framemodel']; $jaar = $a['Modeljaar']
        $rec.size = $(if ($a['Framehoogte']) { $a['Framehoogte'] + " cm" } else { $null })
        $rec.color = TitleCaseColor $a['Kleur specifiek']
        if (-not $rec.color -and $a['Primaire basiskleur']) { $rec.color = TitleCaseColor $a['Primaire basiskleur'] }
        # YAPISAL KOD: tedarikci Description'indan beden token'i + renk metni cikarinca kalan
        # (motor tipi MM/SDFM, Enviolo/Auto, ND3/ND7, AL/AL+ gibi TUM gercek farklar korunur)
        # NOT: renk eslesmesi AKSAN + buyuk/kucuk harf DUYARSIZ (Frappé vs Frappe vakasi 2026-07-06)
        $struct = StripDiacritics "$($a['__desc'])"
        if ($a['Kleur specifiek']) {
            $colPat = [regex]::Escape((StripDiacritics $a['Kleur specifiek']))
            $struct = [regex]::Replace($struct, $colPat, ' ', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        $struct = $struct -creplace '\b[HLU]\d{2}\b', ' '          # H50 / L57 beden token'i
        $struct = RemoveColorWords $struct $a['Kleur specifiek']   # typo'lu renk kalintilari (Jett vs Jet)
        $struct = $struct -creplace '(?i)(?<=^|\s)(Matt|Matte|Gloss|Glans|Glanzend)(?=$|\s)', ' '   # yalniz kalan cila sozcukleri
        $struct = ($struct -creplace '\s+-\s+|\s+-$|^-\s+', ' ')   # sarkan tireler
        $struct = ($struct -creplace '\s+', ' ').Trim()
        if (-not $struct) { $skipped += [PSCustomObject]@{sku=$sku; sebep='KB struct bos'; title=$p.title}; continue }
        # marka struct'in basinda zaten varsa yinelenmesin (Alpina Alpina Trial vakasi)
        if ($struct.ToLowerInvariant().StartsWith(("$($a['Merk'])".ToLowerInvariant() + ' '))) {
            $struct = $struct.Substring("$($a['Merk'])".Length).Trim()
        }
        $rec.supplierBrand = $a['Merk']
        # KULLANICI KARARI (2026-07-06 aksam): renkler AYRI URUN - renk anahtara ve basliga girer
        $rec.key = ("KB|" + $a['Merk'] + "|" + $struct + "|" + $doel + "|" + $frmodel + "|" + $jaar + "|" + $rec.color).ToLowerInvariant()
        $tparts = @($a['Merk'], $struct)
        if ($doel) { $tparts += $doel }
        if ($jaar) { $tparts += $jaar }
        $rec.groupTitle = (($tparts -join ' ') + $(if ($rec.color -and $rec.color -ne 'Standaard') { ' - ' + $rec.color } else { '' }))
    }
    elseif ($accBySku.ContainsKey($sku)) {
        $a = $accBySku[$sku]
        $rec.kaynak = 'ACC'
        $desc = "$($a.description)".Trim()
        foreach ($b in 'Batavus ','Sparta ','Loekie ') { if ($desc.StartsWith($b)) { $desc = $desc.Substring($b.Length) } }
        $pc = Parse-AccCaption $a.caption (("$desc" -split '\s+')[0])
        # desc bazen "(Light silver Matt)" gibi renk + sonda harf beden tasir - ayikla
        if ($desc -cmatch '\(([^)]*(?:Matt|Matte|Gloss|Glans)[^)]*)\)') {
            if (-not $pc.color) { $pc.color = $Matches[1].Trim() }
            $desc = ($desc -creplace [regex]::Escape($Matches[0]), ' ')
        }
        if ($desc -cmatch '^(.*\S)\s+(S|M|L|XL)$') {
            if (-not $pc.size) { $pc.size = $Matches[2] }
            $desc = $Matches[1]
        }
        $desc = (($desc -creplace '\s+', ' ')).Trim()
        # yapisal koddan COLn + renk-cila token'lari (GROEN-MAT, SMOKEBLACK-MAT...) cikar -> renkten bagimsiz model kodu
        $structNorm = $null
        if ($pc.struct) {
            $sN = [regex]::Replace($pc.struct, '(?i)\([^)]*(mat|matt|matte|glans|gloss)[^)]*\)', ' ')   # parantezli renk grubu
            $structNorm = (($sN -split '\s+' | Where-Object {
                $_ -and $_ -cnotmatch '^COL\d$' -and $_ -cnotmatch '^[A-Z]*-?(MAT|MATT|MATTE|GLANS|GLOSS)$'
            }) -join ' ')
        }
        $rec.size = $pc.size
        # caption bedeni vermezse Shopify specs.framesize'dan dene (Senz gibi ayni-caption'li seriler)
        if (-not $rec.size -and $p.framesize -and $p.framesize.value) {
            $fv = "$($p.framesize.value)".Trim()
            if ($fv -cmatch '^(\d{2})') { $rec.size = $Matches[1] + " cm" }
            elseif ($fv -cmatch '^(S|M|L|XL)$') { $rec.size = $fv }
        }
        $col = TitleCaseColor $pc.color
        # renk bos ise ayni yapisal kod + COLn tasiyan kardesten tamamlanacak (asagida)
        $rec.color = $col
        $rec.PSObj = $null
        $colToken = $(if ($pc.struct -cmatch '(COL\d)') { $Matches[1] } else { $null })
        $rec.supplierBrand = $a.brand
        # KULLANICI KARARI (2026-07-06 aksam): renkler AYRI URUN - renk anahtara girer.
        # NOT: rengi bos olanlar asagida kardesten tamamlaniyor; anahtar colToken ile kurulur ki tamamlama grubu bolmesin
        $colKeyPart = if ($col) { $col } elseif ($colToken) { $colToken } else { 'std' }
        $rec.key = ("ACC|" + $a.brand + "|" + $desc + "|" + $pc.frametype + "|" + $structNorm + "|" + $colKeyPart).ToLowerInvariant()
        $rec['colToken'] = $colToken
        $tparts = @($a.brand, $desc)
        if ($pc.frametype) { $tparts += $pc.frametype }
        # model yili basliga (eski/yeni nesil ayni adla karismasin) - Shopify specs.model_year'dan
        if ($p.modelYear -and "$($p.modelYear.value)" -cmatch '^(19|20)\d\d$') { $tparts += "$($p.modelYear.value)" }
        $rec.groupTitle = ($tparts -join ' ')   # renk son asamada (kardesten tamamlama sonrasi) eklenir
    }
    else {
        $skipped += [PSCustomObject]@{sku=$sku; sebep='tedarikci verisi yok'; title=$p.title}
        continue
    }
    $items += [PSCustomObject]$rec
}
Write-Host ("Cozumlenen bisiklet: " + $items.Count + " | atlanan: " + $skipped.Count)

# ---- AYNI SKU'LU DUPLIKE URUNLER: en iyisini tut, digerlerini arsiv listesine at ----
# (iki ayri import kosusu ayni bisikleti iki kez eklemis - musteri cift goruyor)
$dupGids = @()
$dedup = @()
foreach ($sg in ($items | Group-Object sku)) {
    if ($sg.Count -eq 1) { $dedup += $sg.Group[0]; continue }
    $ranked = $sg.Group | Sort-Object @{e={$_.images.Count};Descending=$true}, @{e={$_.status -eq 'ACTIVE'};Descending=$true}
    $keep = $ranked[0]; $losers = @($ranked | Select-Object -Skip 1)
    # renk bilgisi kaybolmasin: tutulanin rengi zayifsa (COLn/Standaard) kaybedenin basligindan dene
    foreach ($l in $losers) {
        if ($keep.color -cmatch '^(COL\d|Standaard)$' -or -not $keep.size) {
            if ($l.title -cmatch '(?:MEISJES|JONGENS|DAMES|HEREN|Meisjes|Jongens|Dames|Heren)\s+([A-Za-z][A-Za-z ]*?)\s+\d' -and $keep.color -cmatch '^(COL\d|Standaard)$') {
                $keep.color = (Get-Culture).TextInfo.ToTitleCase($Matches[1].ToLowerInvariant().Trim())
            }
        }
        $dupGids += [PSCustomObject]@{ sku=$sg.Name; gid=$l.gid; title=$l.title; tutulan=$keep.title }
    }
    $dedup += $keep
}
$items = $dedup
Write-Host ("SKU-duplike temizligi: " + $dupGids.Count + " kopya arsivlenecek; kalan: " + $items.Count)

# ---- Accell bos renkleri kardesten tamamla (ayni key + ayni COLn) ----
foreach ($grp in ($items | Where-Object { $_.kaynak -eq 'ACC' } | Group-Object key)) {
    $known = @{}
    foreach ($it in $grp.Group) { if ($it.color -and $it.colToken) { $known[$it.colToken] = $it.color } }
    foreach ($it in $grp.Group) {
        if (-not $it.color) {
            if ($it.colToken -and $known.ContainsKey($it.colToken)) { $it.color = $known[$it.colToken] }
            elseif ($it.colToken) { $it.color = $it.colToken }   # son care: COL2 gibi
            else { $it.color = 'Standaard' }
        }
    }
}
foreach ($it in ($items | Where-Object { -not $_.color })) { $it.color = 'Standaard' }
# ACC basliklarina rengi simdi ekle (kardesten tamamlama bittikten sonra)
foreach ($it in ($items | Where-Object { $_.kaynak -eq 'ACC' -and $_.color -and $_.color -ne 'Standaard' })) {
    $it.groupTitle = $it.groupTitle + ' - ' + $it.color
}

# ---- gruplar + cakisma kontrolu ----
# eski kosuda arsivlenen urunler: tek uyeli gruplar bile plana girmeli (yoksa vitrinden kaybolur)
$archivedOld = New-Object System.Collections.Generic.HashSet[string]
foreach ($f in @("$d\merge_done_v1.csv", "$d\merge_done.csv")) {
    if (Test-Path $f) { foreach ($r in (Import-Csv $f)) { foreach ($g2 in ($r.old_gids -split ';')) { if ($g2) { [void]$archivedOld.Add($g2) } } } }
}
if (Test-Path "$d\merge_duplicate_products.csv") { foreach ($r in (Import-Csv "$d\merge_duplicate_products.csv")) { if ($r.gid) { [void]$archivedOld.Add($r.gid) } } }
Write-Host ("arsivlenmis eski urun (yeniden uretim adayi): " + $archivedOld.Count)

$plan = @(); $conflictItems = @(); $singletons = @()
foreach ($grp in ($items | Group-Object key)) {
    $members = @($grp.Group)
    # ayni (beden,renk) iki kez -> grubu parcalamak yerine cakisanlari disari al
    $dups = $members | Group-Object { "$($_.size)|$($_.color)" } | Where-Object { $_.Count -gt 1 }
    if ($dups) {
        $dupSkus = @($dups | ForEach-Object { $_.Group } | ForEach-Object { $_.sku })
        $conflictItems += @($members | Where-Object { $dupSkus -contains $_.sku })
        $members = @($members | Where-Object { $dupSkus -notcontains $_.sku })
    }
    if ($members.Count -eq 1 -and -not $archivedOld.Contains($members[0].gid)) { $singletons += $members; continue }
    if ($members.Count -lt 1) { continue }
    $sizes = @($members | ForEach-Object { $_.size } | Select-Object -Unique | Sort-Object { if ($_ -cmatch '(\d+)') { [int]$Matches[1] } else { 999 } })
    $colors = @($members | ForEach-Object { $_.color } | Select-Object -Unique)
    $plan += [PSCustomObject]@{
        key = $grp.Name
        title = $members[0].groupTitle
        vendor = $members[0].supplierBrand
        kaynak = $members[0].kaynak
        sizes = $sizes; colors = $colors
        memberCount = $members.Count
        members = $members
    }
}
Write-Host ""
Write-Host ("PLAN: " + $plan.Count + " birlesik urun <- " + (@($plan | ForEach-Object { $_.members }).Count) + " eski urun")
Write-Host ("Tekli model (birlesecek kardesi yok, oldugu gibi kalir): " + $singletons.Count)
Write-Host ("GERCEK CAKISMA (elle bakilacak): " + $conflictItems.Count)
Write-Host ("Tedarikci verisi olmayan (dokunulmaz): " + $skipped.Count)
$dupGids | Export-Csv "$d\merge_duplicate_products.csv" -NoTypeInformation -Encoding UTF8

# ---- baslik cakismasi ayristirma: ayni baslikli gruplara anahtarin ayirt edici parcasini ekle ----
$ti2 = (Get-Culture).TextInfo
foreach ($col in ($plan | Group-Object title | Where-Object { $_.Count -gt 1 })) {
    $keyTokens = @{}
    foreach ($g in $col.Group) { $keyTokens[$g.key] = @(($g.key -split '[| ]') | Where-Object { $_ }) }
    foreach ($g in $col.Group) {
        $others = @($col.Group | Where-Object { $_.key -ne $g.key })
        $distinct = @($keyTokens[$g.key] | Where-Object { $tok = $_; @($others | Where-Object { $keyTokens[$_.key] -contains $tok }).Count -lt $others.Count } | Select-Object -First 2)
        if ($distinct.Count) {
            $suffix = ($distinct | ForEach-Object { $ti2.ToTitleCase($_) }) -join ' '
            $g.title = $g.title + ' ' + $suffix
        }
    }
}
$stillCol = @($plan | Group-Object title | Where-Object { $_.Count -gt 1 })
Write-Host ("Baslik cakismasi (ayristirma sonrasi): " + $stillCol.Count)

# gozden gecirme dosyalari
$review = foreach ($g in $plan) { foreach ($m in $g.members) {
    [PSCustomObject]@{ grup=$g.title; key=$g.key; sku=$m.sku; beden=$m.size; renk=$m.color; fiyat=$m.price; adet=$m.qty; eskiBaslik=$m.title }
} }
$review | Export-Csv "$d\merge_plan_review.csv" -NoTypeInformation -Encoding UTF8
$conflictItems | Select-Object sku, size, color, price, title | Export-Csv "$d\merge_plan_disarida.csv" -NoTypeInformation -Encoding UTF8
[IO.File]::WriteAllText("$d\merge_plan.json", ($plan | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($true))
Write-Host "Yazildi: merge_plan.json, merge_plan_review.csv, merge_plan_disarida.csv"
Write-Host ""
Write-Host "=== ORNEK 6 GRUP ==="
$plan | Sort-Object memberCount -Descending | Select-Object -First 6 | ForEach-Object {
    Write-Host ("  [" + $_.memberCount + "] " + $_.title + " | bedenler: " + ($_.sizes -join ',') + " | renkler: " + ($_.colors -join ' / '))
}
Write-Host "=== VARYANT SINIRI KONTROLU (>100) ==="
@($plan | Where-Object { $_.memberCount -gt 100 }) | ForEach-Object { Write-Host ("  ASIRI: " + $_.title + " = " + $_.memberCount) }
Write-Host "=== AKU SECENEGI TUTARLILIGI (grup ici farkli battery_options) ==="
$battDiff = 0
foreach ($g in $plan) {
    $u = @($g.members | ForEach-Object { "$($_.battOpts)" } | Select-Object -Unique)
    if ($u.Count -gt 1) { $battDiff++; if ($battDiff -le 5) { Write-Host ("  FARKLI: " + $g.title + " (" + $u.Count + " ayri deger)") } }
}
Write-Host ("Aku secenegi grup ici farkli olan grup: " + $battDiff)
