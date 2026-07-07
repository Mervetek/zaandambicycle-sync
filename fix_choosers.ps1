# "Kies een accu / lader" secici urunlerinin stok durumlarini tedarikci verisiyle gunceller
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"

# --- seciciler ve varyasyonlari ---
$choosers = Invoke-RestMethod "$wooBase/products?per_page=100&search=Kies een&status=publish&$wooAuth" -TimeoutSec 60
$vars = @()
foreach ($p in $choosers) {
    $vs = Invoke-RestMethod "$wooBase/products/$($p.id)/variations?per_page=50&$wooAuth" -TimeoutSec 60
    foreach ($v in $vs) { $vars += [PSCustomObject]@{ product_id = $p.id; product_name = $p.name; variation_id = $v.id; sku = "$($v.sku)".Trim(); cur = $v.stock_status } }
    Start-Sleep -Milliseconds 200
}
Write-Host "secici: $($choosers.Count) urun, $($vars.Count) secenek"
$skus = @($vars | ForEach-Object { $_.sku } | Where-Object { $_ } | Select-Object -Unique)

# --- Accell sorgusu ---
$accMap = @{}
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
for ($i = 0; $i -lt $skus.Count; $i += 20) {
    $batch = $skus[$i..([Math]::Min($i+19, $skus.Count-1))]
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($code in $batch) { $a = $r.result.PSObject.Properties[$code]; if ($a -and $a.Value) { $accMap[$code] = $a.Value } }
    } catch { }
    Start-Sleep -Milliseconds 300
}
Write-Host "accell eslesen: $($accMap.Count)"

# --- Kruitbosch sorgusu (C-kodlu aku/lader) ---
$kbMap = @{}
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
$kbSkus = @($skus | Where-Object { -not $accMap.ContainsKey($_) })
for ($i = 0; $i -lt $kbSkus.Count; $i += 50) {
    $batch = $kbSkus[$i..([Math]::Min($i+49, $kbSkus.Count-1))]
    try {
        $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($batch -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
        foreach ($s in $r.StocksAndPrices) { $kbMap["$($s.ProductCode)".Trim()] = $s }
    } catch { }
    Start-Sleep -Milliseconds 300
}
Write-Host "kruitbosch eslesen: $($kbMap.Count)"

# --- hafta hesabi ---
$curWeek = [int](Get-Date -UFormat %V); $curYear = (Get-Date).Year

# --- yeni durumlari hesapla ve uygula ---
$updByProduct = @{}
foreach ($v in $vars) {
    if (-not $v.sku) { continue }
    $new = $null
    if ($accMap.ContainsKey($v.sku)) {
        $a = $accMap[$v.sku]; $st = [int]$a.stock_status
        if ($st -le 2) { $new = 'instock' }
        elseif ($st -eq 3) {
            $wk = [int]$a.stock_week; $yr = [int]$a.stock_year
            if ($yr -lt 9999 -and $wk -lt 99 -and ((($yr - $curYear) * 52 + ($wk - $curWeek)) -le 26)) { $new = 'onbackorder' } else { $new = 'outofstock' }
        } else { $new = 'outofstock' }
    } elseif ($kbMap.ContainsKey($v.sku)) {
        $s = $kbMap[$v.sku]
        $new = if ([int]$s.AvailabilityId -in 1,2) { 'instock' } else { 'outofstock' }
    }
    if ($new -and $new -ne $v.cur) {
        if (-not $updByProduct.ContainsKey($v.product_id)) { $updByProduct[$v.product_id] = @() }
        $updByProduct[$v.product_id] += @{ id = $v.variation_id; stock_status = $new }
        Write-Host "DEGISIYOR: [$($v.sku)] $($v.cur) -> $new  ($($v.product_name) #$($v.product_id))"
    }
}
$fixed = 0
foreach ($prodId in $updByProduct.Keys) {
    try {
        $null = Invoke-RestMethod -Method Post -Uri "$wooBase/products/$prodId/variations/batch?$wooAuth" -Body (@{ update = $updByProduct[$prodId] } | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 60
        $fixed += $updByProduct[$prodId].Count
    } catch { Write-Host "[HATA] $prodId : $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 300
}
Write-Host "DONE. guncellenen secenek: $fixed"
