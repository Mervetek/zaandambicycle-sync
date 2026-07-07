# ACCELL TAM KATALOG KESFI (salt okunur): genisleyen terim taramasiyla tum Batavus/Sparta/Loekie modellerini bulur
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$brands = @('Batavus','Sparta','Loekie')

# --- tohum terimler: marka adlari + mevcut verideki model kelimeleri ---
$terms = New-Object System.Collections.Generic.Queue[string]
$seen = New-Object System.Collections.Generic.HashSet[string]
function Add-Term($t) {
    $t = "$t".Trim().ToLower()
    if ($t.Length -ge 3 -and $t -notmatch '^\d+$' -and $t -notmatch '[^a-z0-9\-]' -and -not $seen.Contains($t)) {
        [void]$seen.Add($t); $terms.Enqueue($t)
    }
}
$brands | ForEach-Object { Add-Term $_ }
$acc = Import-Csv "$dataDir\accentry_stok.csv"
foreach ($row in $acc) { foreach ($w in ("$($row.description)" -split '[\s/]+')) { Add-Term $w } }
$ap = Import-Csv "$dataDir\admin_products.csv"
foreach ($p in ($ap | Where-Object { $_.categories -match 'Batavus|Sparta|Loekie' })) { foreach ($w in ("$($p.name)" -split '[\s/]+')) { Add-Term $w } }
Write-Host "tohum terim: $($terms.Count)"

# --- tarama ---
$models = @{}   # description -> model bilgisi
$codes = New-Object System.Collections.Generic.HashSet[string]
$qCount = 0
while ($terms.Count -gt 0 -and $qCount -lt 400) {
    $t = $terms.Dequeue(); $qCount++
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/search?text=$([uri]::EscapeDataString($t))&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 30
        foreach ($m in @($r.result | Where-Object { $_.article_type -eq 'F' -and $_.brand -in $brands })) {
            $key = "$($m.description)|$($m.caption)"
            if (-not $models.ContainsKey($key)) {
                $models[$key] = $m
                foreach ($c in @($m.article_codes)) { [void]$codes.Add("$c") }
                # yeni model kelimelerini terim olarak ekle
                foreach ($w in ("$($m.description)" -split '[\s/]+')) { Add-Term $w }
            }
        }
    } catch { }
    if ($qCount % 40 -eq 0) { Write-Host "sorgu $qCount | kuyruk $($terms.Count) | model $($models.Count) | kod $($codes.Count)" }
    Start-Sleep -Milliseconds 250
}
Write-Host "tarama bitti: $qCount sorgu | model-varyant $($models.Count) | benzersiz kod: $($codes.Count)"

# --- mevcut magazayla kiyasla ---
$existing = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $acc) { [void]$existing.Add("$($row.sku)".Trim()) }
$kb = Get-Content "$dataDir\kruitbosch_stok.csv" | Select-Object -Skip 1 | ForEach-Object { ($_ -split ',')[0] -replace '"','' }
foreach ($k in $kb) { [void]$existing.Add("$k".Trim()) }
$newCodes = @($codes | Where-Object { -not $existing.Contains($_) })
Write-Host "YENI kod (magazada olmayan): $($newCodes.Count)"
$newCodes | ForEach-Object { [PSCustomObject]@{ sku = $_ } } | Export-Csv "$dataDir\accell_yeni_kodlar.csv" -NoTypeInformation -Encoding utf8

# --- yeni kodlarin stok/marka dokumu (20'li partiler) ---
$sum = @{}
$inStock = 0
for ($i = 0; $i -lt $newCodes.Count; $i += 20) {
    $batch = @($newCodes[$i..([Math]::Min($i+19, $newCodes.Count-1))])
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($c in $batch) {
            $a = $r.result.PSObject.Properties[$c]
            if ($a -and $a.Value) {
                $b = "$($a.Value.brand)"
                if (-not $sum.ContainsKey($b)) { $sum[$b] = @{ toplam = 0; stokta = 0 } }
                $sum[$b].toplam++
                if ([int]$a.Value.stock_status -le 2) { $sum[$b].stokta++; $inStock++ }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 300
}
Write-Host ""
Write-Host "=== YENI MODELLERIN DOKUMU ==="
foreach ($k in $sum.Keys) { "{0,-10} toplam: {1,4} | su an stokta: {2}" -f $k, $sum[$k].toplam, $sum[$k].stokta }
Write-Host "TOPLAM stokta yeni bisiklet: $inStock"
