# Woo'daki satin alinabilir gorunen Batavus urunlerini canli Accell verisiyle karsilastirir
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"

# 1) Woo: Batavus urunleri (canli durum)
$bata = @()
for ($page = 1; $page -le 5; $page++) {
    $r = Invoke-RestMethod "$wooBase/products?per_page=100&page=$page&status=publish&$wooAuth" -TimeoutSec 60
    if (-not $r) { break }
    $bata += @($r | Where-Object { ($_.categories | ForEach-Object { $_.name }) -match 'Batavus' })
    if ($r.Count -lt 100) { break }
    Start-Sleep -Milliseconds 300
}
Write-Host "Batavus urun: $($bata.Count)"
$buyable = @($bata | Where-Object { $_.stock_status -in 'instock','onbackorder' })
Write-Host "satin alinabilir gorunen (instock/onbackorder): $($buyable.Count)"

# 2) varyasyon SKU'lari
$rows = @()
foreach ($p in $buyable) {
    $vs = Invoke-RestMethod "$wooBase/products/$($p.id)/variations?per_page=100&$wooAuth" -TimeoutSec 60
    foreach ($v in $vs) {
        if ($v.stock_status -in 'instock','onbackorder') {
            $rows += [PSCustomObject]@{ urun = $p.name; urun_durum = $p.stock_status; sku = "$($v.sku)".Trim(); beden = (@($v.attributes | ForEach-Object { $_.option }) -join '/'); woo_durum = $v.stock_status }
        }
    }
    Start-Sleep -Milliseconds 250
}
Write-Host "satin alinabilir varyasyon: $($rows.Count)"

# 3) Accell canli sorgu
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$skus = @($rows | ForEach-Object { $_.sku } | Where-Object { $_ } | Select-Object -Unique)
$accMap = @{}
for ($i = 0; $i -lt $skus.Count; $i += 20) {
    $batch = $skus[$i..([Math]::Min($i+19, $skus.Count-1))]
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($code in $batch) { $a = $r.result.PSObject.Properties[$code]; if ($a -and $a.Value) { $accMap[$code] = $a.Value } }
    } catch { }
    Start-Sleep -Milliseconds 350
}

# 4) karsilastir
Write-Host ""
Write-Host "=== KARSILASTIRMA (Woo satin alinabilir vs Accell canli) ==="
foreach ($row in $rows) {
    $a = $accMap[$row.sku]
    if (-not $a) { $acc = 'ACCELL KAYDI YOK'; }
    else {
        $acc = if ([int]$a.stock -gt 0 -or [int]$a.stock_status -le 2) { "VAR (stok $($a.stock), st$($a.stock_status))" }
               elseif ([int]$a.stock_status -eq 3) { "TARIHLI BEKLEME (hafta $($a.stock_week)/$($a.stock_year))" }
               else { "YOK (st$($a.stock_status))" }
    }
    $flag = if ($acc -match '^YOK|KAYDI YOK') { ' <<< UYUSMAZLIK' } else { '' }
    "{0} | {1} | woo:{2} | accell:{3}{4}" -f $row.urun, $row.beden, $row.woo_durum, $acc, $flag
}
