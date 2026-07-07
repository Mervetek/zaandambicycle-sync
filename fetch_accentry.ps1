# Accentry (Accell) API'den site Accell-marka SKU'larinin stok verisini ceker
param(
    [Parameter(Mandatory=$true)][string]$Username,
    [Parameter(Mandatory=$true)][string]$Password
)
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$gw = "https://api-gateway.accentry.com"

# 1) Auth
$body = @{ username = $Username; password = $Password } | ConvertTo-Json
$auth = (Invoke-RestMethod -Method Post -Uri "$gw/authorize" -Body $body -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
if (-not $auth) { Write-Host "AUTH FAIL"; exit 1 }
$h = @{ Authentication = "Bearer $auth"; accept = "application/json"; "X-version" = "2.0" }
Write-Host "Accentry auth OK"

# 2) Sitedeki Accell markali urunlerin SKU'lari (Batavus, Sparta, Loekie)
$ap = Import-Csv "$dataDir\admin_products.csv"
$av = Import-Csv "$dataDir\admin_variations.csv"
$accellIds = @{}
foreach ($p in ($ap | Where-Object { $_.categories -match 'Batavus|Sparta|Loekie' })) { $accellIds[$p.id] = $p }
$skus = New-Object System.Collections.Generic.HashSet[string]
foreach ($v in $av) { if ($accellIds.ContainsKey($v.product_id) -and "$($v.sku)".Trim()) { [void]$skus.Add("$($v.sku)".Trim()) } }
foreach ($p in $accellIds.Values) { if ("$($p.sku)".Trim()) { [void]$skus.Add("$($p.sku)".Trim()) } }
$skuList = @($skus)
Write-Host "Sorgulanacak Accell SKU: $($skuList.Count)"

# 3) 20'serli partilerle articles?c=... sorgula
$rows = New-Object System.Collections.ArrayList
$notFound = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $skuList.Count; $i += 20) {
    $batch = $skuList[$i..([Math]::Min($i+19, $skuList.Count-1))]
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    try {
        $h["fe-request-id"] = [guid]::NewGuid().ToString()
        $r = Invoke-RestMethod -Uri "$gw/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $h -TimeoutSec 60
        foreach ($code in $batch) {
            $a = $r.result.PSObject.Properties[$code]
            if ($a -and $a.Value) {
                $v = $a.Value
                [void]$rows.Add([PSCustomObject]@{
                    sku = $code; brand = $v.brand; caption = $v.caption; description = $v.description
                    stock = $v.stock; stock_status = $v.stock_status
                    stock_week = $v.stock_week; stock_year = $v.stock_year
                    gross_price = $v.gross_price.value
                    retail_price = $v.retail_price.value
                    collection_status = $v.collection_status
                    authorized_to_order = $v.authorized_to_order
                    model_code = $v.model_code
                    images = (@($v.images) | Select-Object -First 8) -join ' | '
                })
            } else { [void]$notFound.Add($code) }
        }
    } catch {
        Write-Host "[HATA] parti $($i/20+1): $($_.Exception.Message)"
        foreach ($code in $batch) { [void]$notFound.Add($code) }
    }
    Write-Host "parti $([int]($i/20)+1)/$([Math]::Ceiling($skuList.Count/20)): toplam $($rows.Count) kayit"
    Start-Sleep -Milliseconds 350
}
$rows | Export-Csv "$dataDir\accentry_stok.csv" -NoTypeInformation -Encoding utf8
$notFound | ForEach-Object { [PSCustomObject]@{ sku = $_ } } | Export-Csv "$dataDir\accentry_bulunamayan.csv" -NoTypeInformation -Encoding utf8
Write-Host "DONE. bulundu: $($rows.Count) | bulunamadi: $($notFound.Count)"
Write-Host "--- stock_status dagilimi ---"
$rows | Group-Object stock_status | Sort-Object Name | Format-Table Name, Count -AutoSize
Write-Host "--- stock > 0 olan: $(@($rows | Where-Object { [int]$_.stock -gt 0 }).Count) ---"
