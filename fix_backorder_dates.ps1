# Woo'da 'onbackorder' gorunen varyasyonlari Accell gelis tarihine gore duzeltir:
# gelis <= 26 hafta -> onbackorder kalir; > 26 hafta veya tarih yok -> outofstock
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"

$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }

$now = Get-Date
# PS 5.1'de ISOWeek tipi yok; -UFormat %V ISO hafta verir
$curWeek = [int](Get-Date -UFormat %V)
$curYear = $now.Year

# tum yayindaki urunler
$all = @()
for ($page = 1; $page -le 5; $page++) {
    $r = Invoke-RestMethod "$wooBase/products?per_page=100&page=$page&status=publish&$wooAuth" -TimeoutSec 60
    if (-not $r) { break }
    $all += $r
    if ($r.Count -lt 100) { break }
    Start-Sleep -Milliseconds 250
}
# Accell markalari + satin alinabilir durumda olanlar
$cand = @($all | Where-Object { ($_.categories | ForEach-Object { $_.name }) -match 'Batavus|Sparta|Loekie' })
Write-Host "kontrol edilecek urun: $($cand.Count)"

$fixed = 0
foreach ($p in $cand) {
    $vs = Invoke-RestMethod "$wooBase/products/$($p.id)/variations?per_page=100&$wooAuth" -TimeoutSec 60
    $upd = @()
    foreach ($v in @($vs | Where-Object { $_.stock_status -in 'onbackorder','outofstock' })) {
        $sku = "$($v.sku)".Trim(); if (-not $sku) { continue }
        $ah["fe-request-id"] = [guid]::NewGuid().ToString()
        try {
            $ar = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?c=$sku&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30
            $a = $ar.result.PSObject.Properties[$sku].Value
        } catch { $a = $null }
        if (-not $a) { continue }
        $st = [int]$a.stock_status
        $new = $null
        if ($st -le 2) { $new = 'instock' }
        elseif ($st -eq 3) {
            $wk = [int]$a.stock_week; $yr = [int]$a.stock_year
            if ($yr -ge 9999 -or $wk -ge 99) { $new = 'outofstock' }
            else {
                $weeksAway = ($yr - $curYear) * 52 + ($wk - $curWeek)
                $new = if ($weeksAway -le 26) { 'onbackorder' } else { 'outofstock' }
                Write-Host "  $sku gelis: hafta $wk/$yr (~$weeksAway hafta) -> $new"
            }
        }
        else { $new = 'outofstock' }
        if ($new -and $v.stock_status -ne $new) { $upd += @{ id = $v.id; stock_status = $new }; Write-Host "DEGISIYOR: $($p.name) [$sku] $($v.stock_status) -> $new" }
        Start-Sleep -Milliseconds 200
    }
    if ($upd.Count) {
        $null = Invoke-RestMethod -Method Post -Uri "$wooBase/products/$($p.id)/variations/batch?$wooAuth" -Body (@{ update = $upd } | ConvertTo-Json -Depth 4) -ContentType 'application/json' -TimeoutSec 60
        $fixed += $upd.Count
    }
    Start-Sleep -Milliseconds 250
}
Write-Host "DONE. duzeltilen varyasyon: $fixed"
