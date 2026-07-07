$ErrorActionPreference = 'Continue'
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
if (-not (Test-Path "$dataDir\products_raw.json")) { Write-Host "FATAL: products_raw.json not found at $dataDir"; exit 1 }
$all = Get-Content "$dataDir\products_raw.json" -Raw | ConvertFrom-Json
$variable = $all | Where-Object { $_.type -eq 'variable' }
$results = New-Object System.Collections.ArrayList
$failed = New-Object System.Collections.ArrayList
$i = 0
foreach ($p in $variable) {
    $i++
    try {
        $html = (Invoke-WebRequest -Uri $p.permalink -UseBasicParsing -TimeoutSec 30).Content
        $m = [regex]::Match($html, 'data-product_variations="([^"]*)"')
        if ($m.Success) {
            $json = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
            $vars = $json | ConvertFrom-Json
            foreach ($v in $vars) {
                $attrs = ($v.attributes.PSObject.Properties | ForEach-Object { $_.Value }) -join ' / '
                [void]$results.Add([PSCustomObject]@{
                    product_id = $p.id
                    product_name = $p.name
                    variation_id = $v.variation_id
                    sku = $v.sku
                    attributes = $attrs
                    is_in_stock = $v.is_in_stock
                    backorders_allowed = $v.backorders_allowed
                    max_qty = $v.max_qty
                    availability = ([regex]::Replace($v.availability_html, '<[^>]+>', '')).Trim()
                    price = $v.display_price
                })
            }
        } else {
            [void]$failed.Add([PSCustomObject]@{ product_id = $p.id; name = $p.name; reason = 'no data-product_variations'; url = $p.permalink })
        }
    } catch {
        [void]$failed.Add([PSCustomObject]@{ product_id = $p.id; name = $p.name; reason = $_.Exception.Message; url = $p.permalink })
    }
    if ($i % 25 -eq 0) { Write-Host "$i / $($variable.Count) done, variations: $($results.Count)" }
    Start-Sleep -Milliseconds 150
}
$results | Export-Csv "$dataDir\variations.csv" -NoTypeInformation -Encoding utf8
$failed | Export-Csv "$dataDir\variations_failed.csv" -NoTypeInformation -Encoding utf8
Write-Host "DONE. variations: $($results.Count), failed products: $($failed.Count)"
