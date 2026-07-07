# ESKI SITE TAM MUTABAKAT: tum urun + varyasyonlari (seciciler dahil) canli tedarikci verisiyle esitler
# KURAL (kullanici karari 2026-07-05, "bayi ile birebir"): SADECE tedarikci rafindaki stok = instock.
#   Accell st1-2 = instock, geri kalan HER SEY (st3 yoldaki dahil) = outofstock. On siparis YOK.
#   Kruitbosch Voldoende/Beperkt = instock | digerleri = outofstock
#   Tedarikci verisi olmayan SKU'lara DOKUNULMAZ.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference = 'Continue'
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"
$curWeek = [int](Get-Date -UFormat %V); $curYear = (Get-Date).Year

# ---------- 1) WOO: tum urunler + varyasyonlar ----------
$products = @()
for ($page = 1; $page -le 6; $page++) {
    $r = Invoke-RestMethod "$wooBase/products?per_page=100&page=$page&status=publish&$wooAuth" -TimeoutSec 60
    if (-not $r) { break }
    $products += $r
    if ($r.Count -lt 100) { break }
    Start-Sleep -Milliseconds 250
}
Write-Host "woo urun: $($products.Count)"
$items = @()   # her satir: guncellenecek birim (varyasyon veya basit urun)
$i = 0
foreach ($p in $products) {
    $i++
    if ($p.type -eq 'variable') {
        try {
            $vs = Invoke-RestMethod "$wooBase/products/$($p.id)/variations?per_page=100&$wooAuth" -TimeoutSec 60
            foreach ($v in $vs) { $items += [PSCustomObject]@{ tip='var'; product_id=$p.id; unit_id=$v.id; sku="$($v.sku)".Trim(); cur=$v.stock_status; urun=$p.name } }
        } catch { Write-Host "[skip] $($p.id) varyasyon cekilemedi" }
    } else {
        $items += [PSCustomObject]@{ tip='simple'; product_id=$p.id; unit_id=$p.id; sku="$($p.sku)".Trim(); cur=$p.stock_status; urun=$p.name }
    }
    if ($i % 50 -eq 0) { Write-Host "woo tarama: $i / $($products.Count)" }
    Start-Sleep -Milliseconds 150
}
Write-Host "toplam birim: $($items.Count)"
$skus = @($items | ForEach-Object { $_.sku } | Where-Object { $_ } | Select-Object -Unique)
Write-Host "benzersiz SKU: $($skus.Count)"

# ---------- 2) KRUITBOSCH ----------
$kbMap = @{}
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
for ($j = 0; $j -lt $skus.Count; $j += 60) {
    $batch = $skus[$j..([Math]::Min($j+59, $skus.Count-1))]
    try {
        $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($batch -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
        foreach ($s in $r.StocksAndPrices) { $kbMap["$($s.ProductCode)".Trim()] = $s }
    } catch { Write-Host "[kb parti hata] $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 300
}
Write-Host "kruitbosch eslesen: $($kbMap.Count)"

# ---------- 3) ACCELL (kruitbosch'ta olmayanlar) ----------
$accMap = @{}
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$accSkus = @($skus | Where-Object { -not $kbMap.ContainsKey($_) })
for ($j = 0; $j -lt $accSkus.Count; $j += 20) {
    $batch = $accSkus[$j..([Math]::Min($j+19, $accSkus.Count-1))]
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($code in $batch) { $a = $r.result.PSObject.Properties[$code]; if ($a -and $a.Value) { $accMap[$code] = $a.Value } }
    } catch { }
    if (($j / 20) % 5 -eq 0) { Write-Host "accell: $j / $($accSkus.Count)" }
    Start-Sleep -Milliseconds 300
}
Write-Host "accell eslesen: $($accMap.Count)"

# ---------- 4) hedef durumlari hesapla ----------
function Get-Target($sku) {
    if ($kbMap.ContainsKey($sku)) {
        $s = $kbMap[$sku]
        if ([int]$s.AvailabilityId -in 1,2) { return 'instock' } else { return 'outofstock' }
    }
    if ($accMap.ContainsKey($sku)) {
        $a = $accMap[$sku]; $st = [int]$a.stock_status
        if ($st -le 2) { return 'instock' }
        return 'outofstock'   # st3 (yoldaki) dahil - bayi portali ile birebir
    }
    return $null
}

$changes = @($items | Where-Object { $_.sku } | ForEach-Object {
    $t = Get-Target $_.sku
    if ($t -and $t -ne $_.cur) { $_ | Add-Member -NotePropertyName yeni -NotePropertyValue $t -PassThru }
})
$covered = @($items | Where-Object { $_.sku -and (Get-Target $_.sku) }).Count
Write-Host ""
Write-Host "kapsanan birim: $covered / $($items.Count) | DEGISECEK: $($changes.Count)"
$changes | Select-Object urun, sku, cur, yeni | Export-Csv "$dataDir\reconcile_changes.csv" -NoTypeInformation -Encoding utf8

# ---------- 5) uygula ----------
$ok = 0; $fail = 0
# varyasyonlar (urun basina batch)
$changes | Where-Object { $_.tip -eq 'var' } | Group-Object product_id | ForEach-Object {
    $upd = @($_.Group | ForEach-Object { @{ id = [int]$_.unit_id; stock_status = $_.yeni } })
    try {
        $null = Invoke-RestMethod -Method Post -Uri "$wooBase/products/$($_.Name)/variations/batch?$wooAuth" -Body (@{ update = $upd } | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 60
        $ok += $upd.Count
    } catch { $fail += $upd.Count; Write-Host "[HATA] urun $($_.Name): $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 300
}
# basit urunler
foreach ($c in @($changes | Where-Object { $_.tip -eq 'simple' })) {
    try {
        $null = Invoke-RestMethod -Method Put -Uri "$wooBase/products/$($c.unit_id)?$wooAuth" -Body (@{ stock_status = $c.yeni } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
        $ok++
    } catch { $fail++ }
    Start-Sleep -Milliseconds 300
}
Write-Host "UYGULANDI: $ok | hata: $fail"
Write-Host "degisiklik dokumu: data\reconcile_changes.csv"
