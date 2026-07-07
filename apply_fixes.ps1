# zaandambicycle.nl - tutarsiz stok durumlarini WooCommerce REST API ile duzeltir.
# Kullanim:
#   On izleme (hicbir sey degistirmez):
#     .\apply_fixes.ps1 -ConsumerKey ck_xxx -ConsumerSecret cs_xxx
#   Gercekten uygula:
#     .\apply_fixes.ps1 -ConsumerKey ck_xxx -ConsumerSecret cs_xxx -Apply
#   ORTA guvenli olanlari da dahil et:
#     .\apply_fixes.ps1 -ConsumerKey ck_xxx -ConsumerSecret cs_xxx -Apply -IncludeMedium
#
# API anahtari: WP Admin > WooCommerce > Instellingen > Geavanceerd > REST API > "Sleutel toevoegen"
# Yetki: Lezen/Schrijven (Read/Write)

param(
    [Parameter(Mandatory=$true)][string]$ConsumerKey,
    [Parameter(Mandatory=$true)][string]$ConsumerSecret,
    [switch]$Apply,
    [switch]$IncludeMedium
)

$base = "https://www.zaandambicycle.nl/wp-json/wc/v3"
$auth = "consumer_key=$ConsumerKey&consumer_secret=$ConsumerSecret"
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$fixes = Import-Csv "$dataDir\duzeltme_listesi.csv"

# Guven seviyesine gore filtrele
$targets = $fixes | Where-Object { $_.guven -eq 'YUKSEK' -or ($IncludeMedium -and $_.guven -eq 'ORTA') }

# Hedef statuyu belirle
$plan = foreach ($f in $targets) {
    $newStatus = switch -Wildcard ($f.onerilen_aksiyon) {
        "*'outofstock'*" { 'outofstock' }
        "*'onbackorder'*" { 'onbackorder' }
        "*'instock'*"    { 'instock' }
        default { $null }
    }
    if ($newStatus) {
        [PSCustomObject]@{ id = $f.id; urun = $f.urun_adi; eski = $f.site_gosterimi; yeni = $newStatus; guven = $f.guven }
    }
}

Write-Host "=== PLAN: $($plan.Count) urun guncellenecek ==="
$plan | Format-Table id, urun, eski, yeni, guven -AutoSize

if (-not $Apply) {
    Write-Host ""
    Write-Host ">>> ON IZLEME modu - hicbir sey degistirilmedi. Uygulamak icin -Apply ekleyin." -ForegroundColor Yellow
    exit 0
}

# Once API erisimini dogrula
try {
    $test = Invoke-RestMethod "$base/products?per_page=1&$auth" -TimeoutSec 30
    Write-Host "API erisimi OK." -ForegroundColor Green
} catch {
    Write-Host "API erisimi BASARISIZ: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$ok = 0; $fail = 0
$log = foreach ($p in $plan) {
    try {
        $body = @{ stock_status = $p.yeni } | ConvertTo-Json
        $r = Invoke-RestMethod -Method Put -Uri "$base/products/$($p.id)?$auth" -Body $body -ContentType 'application/json' -TimeoutSec 30
        $ok++
        Write-Host "[OK]   $($p.id) $($p.urun) -> $($p.yeni)"
        [PSCustomObject]@{ id=$p.id; urun=$p.urun; yeni=$p.yeni; sonuc='OK'; hata='' }
    } catch {
        $fail++
        Write-Host "[HATA] $($p.id) $($p.urun): $($_.Exception.Message)" -ForegroundColor Red
        [PSCustomObject]@{ id=$p.id; urun=$p.urun; yeni=$p.yeni; sonuc='HATA'; hata=$_.Exception.Message }
    }
    Start-Sleep -Milliseconds 300
}
$log | Export-Csv "$dataDir\apply_fixes_log.csv" -NoTypeInformation -Encoding utf8
Write-Host ""
Write-Host "=== BITTI: $ok basarili, $fail hatali. Log: data\apply_fixes_log.csv ==="
