# ACCELL BOSLUK TARAMASI (salt okunur): bilinen bisiklet kodlarinin komsu araliklarini sondalar,
# magazada/veride OLMAYAN gecerli bisiklet kodlarini bulur (arama ucu 5-sonuc kisitli oldugundan
# kartopu kesfi renk varyantlarini kaciriyordu - Finez PT Burgundy vakasi 2026-07-06).
# Cikti: data\accell_gap_codes.csv
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$d = Join-Path $baseDir "data"
$cfg = @{}; Get-Content (Join-Path $baseDir "sync.env") | ForEach-Object { if ($_ -cmatch '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$ab = @{ username = $cfg.ACCELL_USERNAME; password = $cfg.ACCELL_PASSWORD } | ConvertTo-Json
function NewAccTok { (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token }
$script:atok = NewAccTok

# bilinen kodlar
$known = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in (Import-Csv "$d\accentry_stok.csv")) { [void]$known.Add("$($row.sku)".Trim()) }
Write-Host ("bilinen kod: " + $known.Count)

# kod = ONEK + SAYI (orn BE102910). Onek bazinda sayi kumeleri -> +-40 genislet, birlestir
$ranges = @{}
foreach ($k in $known) {
    if ($k -cmatch '^([A-Z]+)(\d{4,})$') {
        $pre = $Matches[1]; $num = [long]$Matches[2]; $w = $Matches[2].Length
        $rk = "$pre|$w"
        if (-not $ranges.ContainsKey($rk)) { $ranges[$rk] = New-Object System.Collections.Generic.HashSet[long] }
        for ($n = $num - 40; $n -le $num + 40; $n++) { if ($n -gt 0) { [void]$ranges[$rk].Add($n) } }
    }
}
$probe = @()
foreach ($rk in $ranges.Keys) {
    $parts = $rk -split '\|'; $pre = $parts[0]; $w = [int]$parts[1]
    foreach ($n in $ranges[$rk]) {
        $code = $pre + ($n.ToString().PadLeft($w, '0'))
        if (-not $known.Contains($code)) { $probe += $code }
    }
}
Write-Host ("sondalanacak kod: " + $probe.Count)

$found = @(); $qi = 0
for ($i = 0; $i -lt $probe.Count; $i += 20) {
    $batch = $probe[$i..([Math]::Min($i+19, $probe.Count-1))]
    $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah = @{ Authentication = "Bearer $script:atok"; accept = "application/json"; "X-version" = "2.0"; "fe-request-id" = [guid]::NewGuid().ToString() }
    try {
        $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($code in $batch) {
            $a = $r.result.PSObject.Properties[$code]
            if ($a -and $a.Value -and $a.Value.description) {
                $v = $a.Value
                # sadece bisiklet markalarimiz + koleksiyonda aktif olanlar
                if ($v.brand -in @('Batavus','Sparta','Loekie') -and "$($v.collection_status)" -in @('A','N')) {
                    $found += [PSCustomObject]@{
                        sku = $code; brand = $v.brand; caption = $v.caption; description = $v.description
                        stock = $v.stock; stock_status = $v.stock_status; stock_week = $v.stock_week; stock_year = $v.stock_year
                        gross_price = $v.gross_price.value; retail_price = $v.retail_price.value
                        collection_status = $v.collection_status; authorized_to_order = $v.authorized_to_order
                        model_code = $v.model_code; images = (@($v.images) | Select-Object -First 8) -join ' | '
                    }
                }
            }
        }
    } catch {
        if ($_.Exception.Message -cmatch '401|Unauthorized') { $script:atok = NewAccTok }
    }
    $qi++
    if ($qi % 20 -eq 0) { Write-Host ("  ... " + ($i+20) + "/" + $probe.Count + " (bulunan: " + $found.Count + ")"); $script:atok = NewAccTok }
    Start-Sleep -Milliseconds 250
}
$found | Export-Csv "$d\accell_gap_codes.csv" -NoTypeInformation -Encoding UTF8
Write-Host ("BULUNAN EKSIK KOD: " + $found.Count + " -> data\accell_gap_codes.csv")
$found | Group-Object description | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object { Write-Host ("  x" + $_.Count + " " + $_.Name + " | " + (@($_.Group | ForEach-Object { $_.caption } | Select-Object -Unique) -join ' / ')) }
