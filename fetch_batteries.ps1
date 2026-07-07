# Her Accell bisikleti icin uyumlu aku + sarj cihazlarini ceker (batteriesandchargers)
param(
    [Parameter(Mandatory=$true)][string]$Username,
    [Parameter(Mandatory=$true)][string]$Password
)
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$gw = "https://api-gateway.accentry.com"
$body = @{ username = $Username; password = $Password } | ConvertTo-Json
$auth = (Invoke-RestMethod -Method Post -Uri "$gw/authorize" -Body $body -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$h = @{ Authentication = "Bearer $auth"; accept = "application/json"; "X-version" = "2.0" }
Write-Host "auth OK"

$acc = Import-Csv "$dataDir\accentry_stok.csv"
$codes = @($acc | ForEach-Object { "$($_.sku)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
Write-Host "taranacak bisiklet kodu: $($codes.Count)"

$links = New-Object System.Collections.ArrayList   # bisiklet -> aku eslesmesi
$items = @{}                                        # benzersiz aku/sarj urunleri
$i = 0
foreach ($code in $codes) {
    $i++
    try {
        $h["fe-request-id"] = [guid]::NewGuid().ToString()
        $r = Invoke-RestMethod -Uri "$gw/articles/$code/batteriesandchargers/?companyGroupCode=ANL&languageCode=nl" -Headers $h -TimeoutSec 30
        foreach ($grp in @('Batteries','Chargers')) {
            foreach ($a in @($r.result.$grp)) {
                if (-not $a -or -not $a.article_code) { continue }
                [void]$links.Add([PSCustomObject]@{ bike_sku = $code; item_sku = $a.article_code; tur = $grp })
                if (-not $items.ContainsKey($a.article_code)) {
                    $items[$a.article_code] = [PSCustomObject]@{
                        sku = $a.article_code; tur = $grp
                        brand = $a.brand; caption = $a.caption; description = $a.description
                        stock = $a.stock; stock_status = $a.stock_status
                        gross_price = $a.gross_price.value; retail_price = $a.retail_price.value
                        images = (@($a.images) | Select-Object -First 4) -join ' | '
                    }
                }
            }
        }
    } catch { }
    if ($i % 50 -eq 0) { Write-Host "$i / $($codes.Count) | eslesme: $($links.Count) | benzersiz urun: $($items.Count)" }
    Start-Sleep -Milliseconds 300
}
$links | Export-Csv "$dataDir\bike_battery_links.csv" -NoTypeInformation -Encoding utf8
$items.Values | Export-Csv "$dataDir\battery_catalog.csv" -NoTypeInformation -Encoding utf8
Write-Host "DONE. eslesme: $($links.Count) | benzersiz aku/sarj: $($items.Count)"
$items.Values | Group-Object tur | Format-Table Name, Count -AutoSize
