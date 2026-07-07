# Eski sitede stok durumu 'outofstock' olan urunleri TASLAGA ceker (geri alinabilir: tekrar publish edilebilir)
# Istisna: "Kies een" seciciler (sayfalara gomulu) ve zaten taslak olanlar
$wooAuth = "consumer_key=ck_6e1926d7542c0cea92687203c7af892de65910eb&consumer_secret=cs_0f75e48e58214345a30dcfb4cbe91d1d2cbe0a56"
$wooBase = "https://www.zaandambicycle.nl/wp-json/wc/v3"
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"

$all = @()
for ($page = 1; $page -le 6; $page++) {
    $r = Invoke-RestMethod "$wooBase/products?per_page=100&page=$page&status=publish&$wooAuth" -TimeoutSec 60
    if (-not $r) { break }
    $all += $r
    if ($r.Count -lt 100) { break }
    Start-Sleep -Milliseconds 250
}
$targets = @($all | Where-Object { $_.stock_status -eq 'outofstock' -and $_.name -notmatch '^Kies een' })
Write-Host "yayinda toplam: $($all.Count) | taslaga cekilecek (stoksuz): $($targets.Count)"
$targets | Select-Object id, name, stock_status | Export-Csv "$dataDir\woo_taslaga_cekilenler.csv" -NoTypeInformation -Encoding utf8

$ok = 0; $fail = 0; $i = 0
foreach ($p in $targets) {
    $i++
    try {
        $null = Invoke-RestMethod -Method Put -Uri "$wooBase/products/$($p.id)?$wooAuth" -Body (@{ status = 'draft' } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
        $ok++
    } catch { $fail++ }
    if ($i % 25 -eq 0) { Write-Host "$i / $($targets.Count) (ok $ok)" }
    Start-Sleep -Milliseconds 350
}
Write-Host "DONE. taslaga cekilen: $ok | hata: $fail"
Write-Host "liste: data\woo_taslaga_cekilenler.csv (geri almak icin bu listeden publish edilir)"
