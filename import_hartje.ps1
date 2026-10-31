param(
    [ValidateSet('Conway','Victoria','Excelsior','Noxon','All')]
    [string]$Brand = 'All',
    [switch]$Apply
)
# Hartje 4 marka import: Conway, Victoria, Excelsior, Noxon
# Kullanim:
#   pwsh -File import_hartje.ps1 -Brand Conway          -> KURU CALISMA
#   pwsh -File import_hartje.ps1 -Brand Conway -Apply    -> Shopify'a yaz
#   pwsh -File import_hartje.ps1 -Brand All -Apply       -> Hepsini yaz
$ErrorActionPreference = 'Stop'
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }

$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $locationId = 118973399427
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$h = @{ "X-Shopify-Access-Token" = $tok }

$pubGid = "gid://shopify/Publication/338868208003"
$pubMutation = 'mutation Pub($id: ID!, $input: [PublicationInput!]!) { publishablePublish(id: $id, input: $input) { userErrors { message } } }'

# Veri dosyasini oku
$dataFile = Join-Path $PSScriptRoot "data\hartje_import_data.csv"
if (-not (Test-Path $dataFile)) {
    Write-Host "[HATA] $dataFile bulunamadi. Once veri dosyasini olusturun."
    exit 1
}
$allData = Import-Csv $dataFile -Delimiter '|'

if ($Brand -ne 'All') {
    $allData = $allData | Where-Object { $_.vendor -eq $Brand }
}
Write-Host ("Import edilecek: {0} urun ({1})" -f $allData.Count, $Brand)

# Mevcut Shopify urunlerini kontrol et (ayni artNr'li varsa atla)
$existingProducts = @()
foreach ($vendor in @('Conway','Victoria','Excelsior','Noxon')) {
    if ($Brand -ne 'All' -and $Brand -ne $vendor) { continue }
    $url = "https://$shop/admin/api/$api/products.json?limit=250&vendor=$vendor&fields=id,title,handle,variants"
    while ($url) {
        $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        $existingProducts += ($resp.Content | ConvertFrom-Json).products
        $url = $null
        if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
        Start-Sleep -Milliseconds 300
    }
}
$existingSkus = @{}
foreach ($ep in $existingProducts) {
    foreach ($v in $ep.variants) {
        if ($v.sku) { $existingSkus[$v.sku] = $ep.id }
    }
}
Write-Host ("Mevcut urunler: {0} (SKU: {1})" -f $existingProducts.Count, $existingSkus.Count)

$created = 0; $skipped = 0; $errors = 0
foreach ($item in $allData) {
    $price = [double]$item.price
    if ($price -le 0) { $skipped++; continue }

    # SKU ile zaten var mi?
    if ($existingSkus.ContainsKey($item.artNr)) {
        Write-Host ("[MEVCUT] {0} {1} (SKU: {2})" -f $item.vendor, $item.model, $item.artNr)
        $skipped++
        continue
    }

    # Urun basligini olustur
    $suffix = if ($item.suffix -and $item.suffix -ne '#1') { " $($item.suffix)" } else { '' }
    $title = "$($item.vendor) $($item.model)$suffix"

    # Kategori -> body_html
    $catNl = switch -Wildcard ($item.category) {
        'Elektro-MTB*'        { 'Elektrische mountainbike' }
        'Elektro-SUV*'        { 'Elektrische SUV fiets' }
        'Elektro-Trekkingrad' { 'Elektrische trekkingfiets' }
        'Elektro-Allroad'     { 'Elektrische allroad fiets' }
        'Elektro-Cityrad'     { 'Elektrische stadsfiets' }
        'Elektro-Urbanrad'    { 'Elektrische urban fiets' }
        'Elektro-Faltrad'     { 'Elektrische vouwfiets' }
        'Gravelbike'          { 'Gravelbike' }
        'MTB Hardtail'        { 'Mountainbike hardtail' }
        'MTB*Kinderrad'       { 'Kinder mountainbike' }
        'MTB*Jugendrad'       { 'Jeugd mountainbike' }
        'ATB-Jugendrad'       { 'ATB jeugdfiets' }
        'ATB-Kinderrad'       { 'ATB kinderfiets' }
        'ATB'                 { 'ATB fiets' }
        'Cityrad'             { 'Stadsfiets' }
        'Trekkingrad'         { 'Trekkingfiets' }
        'Singlespeed'         { 'Singlespeed fiets' }
        'Urbanrad'            { 'Urban fiets' }
        'Kinderrad'           { 'Kinderfiets' }
        'Jugendrad'           { 'Jeugdfiets' }
        'Lauflernrad'         { 'Loopfiets' }
        'Hollandrad'          { 'Hollandse fiets' }
        'Klapprad'            { 'Vouwfiets' }
        'Crossrad'            { 'Crossfiets' }
        'Rennrad'             { 'Racefiets' }
        default               { $item.category }
    }
    $bodyHtml = "<p><strong>$catNl</strong></p><p>$($item.vendor) $($item.model) - Beschikbaar bij Zaandam Bicycle.</p>"

    # Tags
    $tags = @($item.vendor, $item.category)
    if ($item.category -like 'Elektro-*' -or $item.category -like 'E-*') { $tags += 'E-Bike' }

    if (-not $Apply) {
        Write-Host ("[KURU] {0,-55} EUR {1,10:N2}  ({2})" -f $title, $price, $item.artNr)
        $created++
        continue
    }

    # Shopify'da urun olustur
    $product = @{
        title     = $title
        vendor    = $item.vendor
        body_html = $bodyHtml
        status    = 'active'
        tags      = ($tags -join ', ')
        variants  = @(@{
            price                = ("{0:0.00}" -f $price).Replace(',', '.')
            sku                  = $item.artNr
            inventory_management = 'shopify'
            inventory_policy     = 'deny'
            requires_shipping    = $true
            taxable              = $true
        })
    }
    $body = @{ product = $product } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        $newId = $resp.product.id
        $variantId = $resp.product.variants[0].id
        $invItemId = $resp.product.variants[0].inventory_item_id
        Write-Host ("[OK] {0} (id:{1})" -f $title, $newId)

        # Online Store'a publish et
        $pubBody = @{ query = $pubMutation; variables = @{ id = "gid://shopify/Product/$newId"; input = @(@{ publicationId = $pubGid }) } } | ConvertTo-Json -Depth 6
        $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($pubBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30

        # Envanter ayarla (stok: 5)
        try {
            $adjBody = @{ location_id = $locationId; inventory_item_id = $invItemId; available_adjustment = 5 } | ConvertTo-Json
            $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/inventory_levels/adjust.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($adjBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
        } catch {}

        $created++
        $existingSkus[$item.artNr] = $newId
    } catch {
        Write-Host ("[HATA] {0}: {1}" -f $title, $_.Exception.Message)
        $errors++
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host ("SONUC: olusturulan={0} | atlanan={1} | hata={2}" -f $created, $skipped, $errors)
if (-not $Apply) { Write-Host "KURU CALISMA. Uygulamak icin: -Apply" }
