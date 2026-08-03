# SALT-OKUNUR: canli Shopify magazasindaki AKTIF urunlerin tedarikci stok-veri kapsami.
# Her aktif varyantin SKU'su KB (StocksAndPrices) veya Accell (articles) canli verisiyle eslesiyor mu?
# Cevaplar: (1) stok verisi olmayan urunler, (2) tam saglam kisim, (3) genel guvenilirlik.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $PSScriptRoot "data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $tok }

# --- 1) Aktif urunler + varyantlar ---
$prods = @()
$url = "https://$shop/admin/api/$api/products.json?limit=250&status=active&fields=id,title,vendor,tags,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
        $vs = @($p.variants | ForEach-Object { [PSCustomObject]@{ sku = "$($_.sku)".Trim(); qty = [int]$_.inventory_quantity; price = [double]$_.price } })
        $prods += [PSCustomObject]@{ id=$p.id; title=$p.title; vendor="$($p.vendor)"; tags="$($p.tags)"; isAcc=("$($p.tags)" -match "Accu's en Laders"); variants=$vs }
    }
    $url = $null; if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
$allSkus = @($prods | ForEach-Object { $_.variants.sku } | Where-Object { $_ } | Select-Object -Unique)
Write-Host "aktif urun: $($prods.Count) | benzersiz SKU: $($allSkus.Count)"

# --- 2) Kruitbosch canli stok ---
$kb = @{}
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
for ($i = 0; $i -lt $allSkus.Count; $i += 60) {
    $batch = @($allSkus[$i..([Math]::Min($i+59, $allSkus.Count-1))])
    try { $r = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($batch -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 90
        foreach ($s in $r.StocksAndPrices) { $kb["$($s.ProductCode)".Trim()] = 1 } } catch {}
    Start-Sleep -Milliseconds 250
}
# --- 3) Accell canli (KB'de olmayanlar) ---
$acc = @{}
$ab = @{ username = $env:ACCELL_USERNAME; password = $env:ACCELL_PASSWORD } | ConvertTo-Json
$atok = (Invoke-RestMethod -Method Post -Uri "https://api-gateway.accentry.com/authorize" -Body $ab -ContentType 'application/json' -TimeoutSec 30).result.bearer_token
$ah = @{ Authentication = "Bearer $atok"; accept = "application/json"; "X-version" = "2.0" }
$rest = @($allSkus | Where-Object { -not $kb.ContainsKey($_) })
for ($i = 0; $i -lt $rest.Count; $i += 20) {
    $batch = @($rest[$i..([Math]::Min($i+19, $rest.Count-1))]); $q = ($batch | ForEach-Object { "c=$_" }) -join '&'
    $ah["fe-request-id"] = [guid]::NewGuid().ToString()
    try { $r = Invoke-RestMethod -Uri "https://api-gateway.accentry.com/articles?$q&companyGroupCode=ANL&languageCode=nl" -Headers $ah -TimeoutSec 60
        foreach ($c in $batch) { $a = $r.result.PSObject.Properties[$c]; if ($a -and $a.Value) { $acc[$c] = 1 } } } catch {}
    Start-Sleep -Milliseconds 250
}
Write-Host "KB eslesen SKU: $($kb.Count) | Accell eslesen SKU: $($acc.Count)"

# --- 4) Urun bazinda kapsam ---
function Src($s) { if ($kb.ContainsKey($s)) { 'KB' } elseif ($acc.ContainsKey($s)) { 'ACC' } else { 'YOK' } }
$rows = foreach ($p in $prods) {
    $skus = @($p.variants.sku | Where-Object { $_ })
    if ($skus.Count -eq 0) { $kap='SKUSUZ' } else {
        $m = @($skus | Where-Object { $kb.ContainsKey($_) -or $acc.ContainsKey($_) })
        $kap = if ($m.Count -eq $skus.Count) { 'TAM' } elseif ($m.Count -gt 0) { 'KISMI' } else { 'YOK' }
    }
    $srcs = @($skus | ForEach-Object { Src $_ } | Select-Object -Unique)
    [PSCustomObject]@{ id=$p.id; title=$p.title; vendor=$p.vendor; isAcc=$p.isAcc; varyant=$skus.Count; kapsam=$kap; kaynak=($srcs -join '/') }
}
$bikes = @($rows | Where-Object { -not $_.isAcc })
$accs  = @($rows | Where-Object { $_.isAcc })

Write-Host ""
Write-Host "=================== BISIKLETLER ($($bikes.Count)) ==================="
Write-Host ("TAM saglam (tum varyant canli stok): {0}" -f @($bikes|?{$_.kapsam -eq 'TAM'}).Count)
Write-Host ("KISMI (bazi varyant ve/siz):          {0}" -f @($bikes|?{$_.kapsam -eq 'KISMI'}).Count)
Write-Host ("VERI YOK (hicbir varyant):            {0}" -f @($bikes|?{$_.kapsam -eq 'YOK'}).Count)
Write-Host ("SKUSUZ:                               {0}" -f @($bikes|?{$_.kapsam -eq 'SKUSUZ'}).Count)
Write-Host ""
Write-Host "--- VERI YOK / KISMI / SKUSUZ bisikletler marka bazinda ---"
@($bikes | Where-Object { $_.kapsam -in 'YOK','KISMI','SKUSUZ' }) | Group-Object vendor | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("  {0,-14} {1}" -f $_.Name, $_.Count)
}
Write-Host ""
Write-Host "=================== AKSESUAR (Accu's en Laders: $($accs.Count)) ==================="
Write-Host ("TAM: {0} | KISMI: {1} | YOK: {2} | SKUSUZ: {3}" -f @($accs|?{$_.kapsam -eq 'TAM'}).Count,@($accs|?{$_.kapsam -eq 'KISMI'}).Count,@($accs|?{$_.kapsam -eq 'YOK'}).Count,@($accs|?{$_.kapsam -eq 'SKUSUZ'}).Count)

# stoksuz/veri yok detay CSV
$rows | Where-Object { $_.kapsam -in 'YOK','KISMI','SKUSUZ' } | Sort-Object isAcc,vendor,title |
    Select-Object kapsam,vendor,title,varyant,kaynak,isAcc,id | Export-Csv "$dataDir\kapsam_bosluk.csv" -NoTypeInformation -Encoding utf8
Write-Host ""
Write-Host "detay -> data\kapsam_bosluk.csv"
