# BEDEN+RENK BIRLESTIRME - Adim 1: tam katalog cikarimi + yedek (salt okunur)
# Cikti: data\merge_source_catalog.json (tum aktif+taslak urunler, spec/varyant/gorsel/metafield)
#        data\merge_groups_report.csv (onerilen gruplama - kontrol icin)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$cfg = @{}; Get-Content (Join-Path $baseDir "sync.env") | ForEach-Object { if ($_ -cmatch '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$shop = $cfg.SHOPIFY_SHOP; $api = "2024-10"
$sb = @{ grant_type="client_credentials"; client_id=$cfg.SHOPIFY_CLIENT_ID; client_secret=$cfg.SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
function GQL($q,$v){
    $b = @{ query=$q; variables=$v } | ConvertTo-Json -Depth 8
    Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
}

$q = @'
query($c:String){ products(first:50, query:"status:active OR status:draft", after:$c){
  nodes{
    id title handle status vendor tags descriptionHtml
    featuredImage{ url }
    media(first:20){ nodes{ ... on MediaImage { image { url } } } }
    variants(first:5){ nodes{ id sku barcode price inventoryQuantity inventoryItem{ id } } }
    brand: metafield(namespace:"specs", key:"brand"){ value }
    model: metafield(namespace:"specs", key:"model"){ value }
    modelYear: metafield(namespace:"specs", key:"model_year"){ value }
    framesize: metafield(namespace:"specs", key:"framesize"){ value }
    colorDesc: metafield(namespace:"specs", key:"color_description"){ value }
    basicColor: metafield(namespace:"specs", key:"basic_color"){ value }
    battOpts: metafield(namespace:"specs", key:"battery_options"){ value }
    chgOpts: metafield(namespace:"specs", key:"charger_options"){ value }
  }
  pageInfo{ hasNextPage endCursor }
} }
'@
$cursor = $null; $all = @(); $page = 0
do {
    $r = GQL $q @{ c = $cursor }
    if ($r.errors) { Write-Host ("HATA: " + $r.errors[0].message); exit 1 }
    $all += @($r.data.products.nodes)
    $pi = $r.data.products.pageInfo; $cursor = $pi.endCursor; $page++
    if ($page % 5 -eq 0) { Write-Host ("  ... " + $all.Count + " urun") }
    Start-Sleep -Milliseconds 300
} while ($pi.hasNextPage)
Write-Host ("Cekilen: " + $all.Count + " urun")
$json = $all | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText((Join-Path $baseDir "data\merge_source_catalog.json"), $json, [Text.UTF8Encoding]::new($true))
Write-Host "Yedek/cikarim yazildi: data\merge_source_catalog.json"

# ---- gruplama onerisi ----
function NormSize($s) {
    if (-not $s) { return $null }
    if ("$s" -cmatch '(\d{2})') { return $Matches[1] + " cm" }
    return $null
}
$rows = @()
foreach ($p in $all) {
    $isAcc = (@($p.tags) -contains "Accu's en Laders")
    $brand = if ($p.brand) { $p.brand.value } else { $null }
    $model = if ($p.model) { $p.model.value } else { $null }
    $size  = NormSize $(if ($p.framesize) { $p.framesize.value } else { $null })
    $color = if ($p.colorDesc) { $p.colorDesc.value } elseif ($p.basicColor) { $p.basicColor.value } else { $null }
    $v = $p.variants.nodes[0]
    $groupable = (-not $isAcc) -and $brand -and $model -and $size
    $key = if ($groupable) { ($brand.Trim() + '|' + $model.Trim()).ToLowerInvariant() } else { '' }
    $rows += [PSCustomObject]@{
        group_key = $key; groupable = $groupable; aksesuar = $isAcc
        brand = $brand; model = $model; size = $size; color = $color
        sku = $v.sku; price = $v.price; qty = $v.inventoryQuantity
        status = $p.status; title = $p.title; product_id = $p.id
    }
}
$rows | Export-Csv (Join-Path $baseDir "data\merge_groups_report.csv") -NoTypeInformation -Encoding UTF8

$g = $rows | Where-Object { $_.groupable } | Group-Object group_key
$multi = @($g | Where-Object { $_.Count -gt 1 })
$single = @($g | Where-Object { $_.Count -eq 1 })
$notGroupable = @($rows | Where-Object { -not $_.groupable -and -not $_.aksesuar })
Write-Host ""
Write-Host ("GRUPLANABILIR MODEL: " + $g.Count + " (coklu: " + $multi.Count + ", tekli: " + $single.Count + ")")
Write-Host ("Birlesecek urun: " + (@($multi | ForEach-Object { $_.Group }).Count) + " -> " + $multi.Count + " urun")
Write-Host ("Gruplanamayan (aksesuar disi): " + $notGroupable.Count)
Write-Host ("Aksesuar (dokunulmaz): " + @($rows | Where-Object { $_.aksesuar }).Count)
Write-Host ""
Write-Host "=== EN BUYUK 8 GRUP ==="
$multi | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
    $sizes = @($_.Group | ForEach-Object { $_.size } | Select-Object -Unique) -join ','
    $colors = @($_.Group | ForEach-Object { $_.color } | Select-Object -Unique)
    Write-Host ("  [" + $_.Count + " urun] " + $_.Group[0].brand + " " + $_.Group[0].model + " | bedenler: " + $sizes + " | renk sayisi: " + $colors.Count)
}
# ayni grup icinde ayni (beden,renk) ikilisi cakisiyor mu?
Write-Host "=== CAKISMA KONTROLU (ayni beden+renk 2 kez) ==="
$conf = 0
foreach ($grp in $multi) {
    $dups = $grp.Group | Group-Object { "$($_.size)|$($_.color)" } | Where-Object { $_.Count -gt 1 }
    foreach ($d in $dups) { $conf++; if ($conf -le 5) { Write-Host ("  " + $grp.Name + " : " + $d.Name + " x" + $d.Count + " (sku: " + (($d.Group | ForEach-Object {$_.sku}) -join ', ') + ")") } }
}
Write-Host ("Toplam cakisan (beden+renk) ikilisi: " + $conf)
