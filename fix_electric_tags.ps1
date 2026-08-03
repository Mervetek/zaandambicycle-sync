# Kruitbosch 'Elektrisch=Ja/Nee' alanina gore E-Bikes etiketini KESIN olarak duzeltir
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# kod -> elektrisch bilgisi
$kb = Get-Content "$dataDir\kruitbosch_products_attrs.json" -Raw | ConvertFrom-Json
$info = @{}
foreach ($p in $kb) {
    $code = "$($p.ProductCode)".Trim()
    $a = @{}
    foreach ($at in @($p.Attributes)) { $a[$at.Attribute] = "$($at.AttributeValue)" }
    if ($a.ContainsKey('Elektrisch')) {
        $info[$code] = @{
            elektrisch = ($a['Elektrisch'] -eq 'Ja')
            vouw = ($p.Description -match 'vouwfiets|compactfiets|cargofiets')
        }
    }
}
Write-Host "Elektrisch bilgisi olan kod: $($info.Count)"

$changed = 0; $checked = 0
foreach ($st in 'active','draft') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&status=$st&fields=id,title,tags,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
            $sku = "$($p.variants[0].sku)".Trim()
            if (-not $sku -or -not $info.ContainsKey($sku)) { continue }
            $checked++
            $i2 = $info[$sku]
            $tags = @(($p.tags -split ',\s*') | Where-Object { $_ })
            $new = [System.Collections.Generic.List[string]]::new()
            $tags | ForEach-Object { [void]$new.Add($_) }
            if ($i2.elektrisch -and $new -notcontains 'E-Bikes') { [void]$new.Add('E-Bikes') }
            if (-not $i2.elektrisch -and $new -contains 'E-Bikes') { [void]$new.Remove('E-Bikes') }
            if ($i2.vouw -and $new -notcontains 'Vouwfietsen') { [void]$new.Add('Vouwfietsen') }
            # elektriksiz + vouw degil + baska tip etiketi yoksa sehir bisikleti say
            if (-not $i2.elektrisch -and -not $i2.vouw -and $new -notcontains 'Stads- en toerfietsen' -and $new -notcontains 'Kinderfietsen') { [void]$new.Add('Stads- en toerfietsen') }
            $newStr = ($new | Select-Object -Unique) -join ', '
            $oldStr = ($tags -join ', ')
            if ($newStr -ne $oldStr) {
                for ($try = 1; $try -le 3; $try++) {
                    try {
                        $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($p.id).json" -Headers $h -Body (@{ product = @{ id = $p.id; tags = $newStr } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60
                        $changed++
                        Write-Host "[duzeltildi] $($p.title.Substring(0,[Math]::Min(45,$p.title.Length))) | elektrisch=$($i2.elektrisch)"
                        break
                    } catch { $code2 = try { [int]$_.Exception.Response.StatusCode } catch { 0 }; if ($code2 -eq 429 -and $try -lt 3) { Start-Sleep -Seconds 2 } else { break } }
                }
                Start-Sleep -Milliseconds 450
            }
        }
        $url = $null
        if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 400
    }
}
Write-Host "DONE. kontrol: $checked | duzeltilen: $changed"
