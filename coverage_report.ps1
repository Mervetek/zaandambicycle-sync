# ESKI SITE: marka bazinda BISIKLET seviyesinde tedarikci veri kapsami (sadece okuma, yazma yok)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$ap = Import-Csv "$dataDir\admin_products.csv"
$av = Import-Csv "$dataDir\admin_variations.csv"

# SKU evreni
$avByProduct = $av | Group-Object product_id -AsHashTable -AsString
$allSkus = @($av | ForEach-Object { "$($_.sku)".Trim() }) + @($ap | ForEach-Object { "$($_.sku)".Trim() })
$allSkus = @($allSkus | Where-Object { $_ } | Select-Object -Unique)
Write-Host "site SKU evreni: $($allSkus.Count)"

# Kruitbosch canli eslesme
$kb = @{}
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
for ($i = 0; $i -lt $allSkus.Count; $i += 60) {
    $batch = $allSkus[$i..([Math]::Min($i+59, $allSkus.Count-1))]
    try { $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($batch -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60; foreach ($s in $r.StocksAndPrices) { $kb["$($s.ProductCode)".Trim()] = 1 } } catch { }
    Start-Sleep -Milliseconds 250
}
# Accell canli eslesme (kalanlar)
$acc = @{}
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$rest = @($allSkus | Where-Object { -not $kb.ContainsKey($_) })
for ($i = 0; $i -lt $rest.Count; $i += 20) {
    $batch = $rest[$i..([Math]::Min($i+19, $rest.Count-1))]
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try { $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60; foreach ($c in $batch) { $a = $r.result.PSObject.Properties[$c]; if ($a -and $a.Value) { $acc[$c] = 1 } } } catch { }
    Start-Sleep -Milliseconds 250
}
Write-Host "kruitbosch eslesen SKU: $($kb.Count) | accell eslesen SKU: $($acc.Count)"

$brandNames = 'Cortina','Batavus','Sparta','QWIC','Alpina','Raleigh','Loekie','UGO'
$bikeCatPattern = 'E-Bikes|Stads|toerfietsen|Kinderfietsen|Vouwfietsen|Raleigh|UGO|Loekie|Elektrische'

$rows = foreach ($p in $ap) {
    $isHelper = $p.name -match '^Kies een'
    $isBike = (-not $isHelper) -and ($p.categories -match $bikeCatPattern) -and ($p.categories -notmatch 'Batterijen|Onderdelen')
    if (-not $isBike) { continue }
    $brand = ($brandNames | Where-Object { $p.categories -match $_ } | Select-Object -First 1); if (-not $brand) { $brand = 'Diger' }
    $vars = $avByProduct["$($p.id)"]
    $skus = if ($vars) { @($vars | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ }) } else { @("$($p.sku)".Trim() | Where-Object { $_ }) }
    $matched = @($skus | Where-Object { $kb.ContainsKey($_) -or $acc.ContainsKey($_) })
    [PSCustomObject]@{ marka = $brand; kapsam = if ($skus.Count -gt 0 -and $matched.Count -eq $skus.Count) { 'TAM' } elseif ($matched.Count -gt 0) { 'KISMI' } else { 'YOK' } }
}
Write-Host ""
Write-Host "=== ESKI SITE - BISIKLET SEVIYESI KAPSAM ==="
$rows | Group-Object marka | Sort-Object Count -Descending | ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{ Marka = $_.Name; Bisiklet = $_.Count
        VeriVar = @($g | Where-Object { $_.kapsam -in 'TAM','KISMI' }).Count
        Tam = @($g | Where-Object { $_.kapsam -eq 'TAM' }).Count
        Kismi = @($g | Where-Object { $_.kapsam -eq 'KISMI' }).Count
        VeriYok = @($g | Where-Object { $_.kapsam -eq 'YOK' }).Count }
} | Format-Table -AutoSize
$t = @($rows); "TOPLAM: $($t.Count) bisiklet | veri var: $(@($t | Where-Object { $_.kapsam -ne 'YOK' }).Count) | veri yok: $(@($t | Where-Object { $_.kapsam -eq 'YOK' }).Count)"
