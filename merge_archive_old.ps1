# BEDEN+RENK BIRLESTIRME - Adim 4: eski tekil urunleri ARSIVLER (silmez!)
# Sadece done-log'da yeni karsiligi OLAN gruplarin uyelerini arsivler + SKU-duplike kopyalari.
# Once dogrulama: yeni urun gercekten var ve varyant sayisi uyusuyor mu?
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$baseDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle"
$d = Join-Path $baseDir "data"
$cfg = @{}; Get-Content (Join-Path $baseDir "sync.env") | ForEach-Object { if ($_ -cmatch '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$shop = $cfg.SHOPIFY_SHOP; $api = "2024-10"
$sb = @{ grant_type="client_credentials"; client_id=$cfg.SHOPIFY_CLIENT_ID; client_secret=$cfg.SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

$plan = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText("$d\merge_plan.json"))) | ForEach-Object { $_ })
$planByKey = @{}; foreach ($g in $plan) { $planByKey[$g.key] = $g }
$done = @(Import-Csv "$d\merge_done.csv")
Write-Host ("done-log: " + $done.Count + " grup")

$archived = 0; $problem = 0
foreach ($row in $done) {
    $g = $planByKey[$row.key]
    if (-not $g) { Write-Host ("UYARI: planda yok: " + $row.key); $problem++; continue }
    # dogrulama: yeni urun var mi, varyant sayisi bekleneni karsiliyor mu?
    try {
        $np = (Invoke-RestMethod -Uri "https://$shop/admin/api/$api/products/$($row.new_id).json?fields=id,status,variants,images" -Headers $h -TimeoutSec 60).product
    } catch { Write-Host ("SORUN: yeni urun yok (" + $row.new_id + ") - " + $g.title); $problem++; continue }
    $expected = @($g.members | ForEach-Object { $_ } | Where-Object { [double]$_.price -gt 0 }).Count
    if (@($np.variants).Count -lt $expected) { Write-Host ("SORUN: varyant eksik (" + @($np.variants).Count + "/" + $expected + ") - " + $g.title); $problem++; continue }
    foreach ($gid in ($row.old_gids -split ';')) {
        $oldId = $gid -replace '.*/',''
        if (-not $oldId) { continue }
        $okd = $false
        for ($try=1; $try -le 5 -and -not $okd; $try++) {
            try {
                $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$oldId.json" -Headers $h -Body (@{ product = @{ id = [long]$oldId; status = 'archived' } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
                $archived++; $okd = $true
            } catch {
                if ([int]$_.Exception.Response.StatusCode -eq 429) { Start-Sleep -Seconds (2*$try) }
                else { Write-Host ("arsiv hatasi " + $oldId + ": " + $_.Exception.Message); break }
            }
        }
        Start-Sleep -Milliseconds 500
    }
}
# SKU-duplike kopyalar (merge disi kalanlar dahil)
$dupFile = "$d\merge_duplicate_products.csv"
if (Test-Path $dupFile) {
    foreach ($r in (Import-Csv $dupFile)) {
        $oldId = $r.gid -replace '.*/',''
        $okd = $false
        for ($try=1; $try -le 5 -and -not $okd; $try++) {
            try {
                $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$oldId.json" -Headers $h -Body (@{ product = @{ id = [long]$oldId; status = 'archived' } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
                $archived++; $okd = $true
            } catch {
                if ([int]$_.Exception.Response.StatusCode -eq 429) { Start-Sleep -Seconds (2*$try) }
                else { Write-Host ("duplike arsiv hatasi " + $oldId + ": " + $_.Exception.Message); break }
            }
        }
        Start-Sleep -Milliseconds 500
    }
}
Write-Host ("BITTI: arsivlenen=" + $archived + " | sorunlu grup=" + $problem)
