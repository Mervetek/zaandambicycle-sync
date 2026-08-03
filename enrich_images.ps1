# Tek-resimli aktif bisikletlere Kruitbosch OriginalImages'in EK goruntulerini ekler (musteri istegi 2026-07-31).
# KB import'u sadece ana resmi cekmisti (IncludeAdditionalImages=false); bu adim eksik gorselleri tamamlar.
# GUVENLI: mevcut resmi SILMEZ (gorselsiz kalma + Flow-draft riski yok); OriginalImages[1..]'i (ana gorunum HARIC) ekler.
# Idempotent: sadece <=1 resimli urunleri isler; zaten cok-resimli olanlari atlar. weekly_discovery'de calisir.
param([switch]$Quiet, [switch]$DryRun, [int]$Limit = 0)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
function Log($m) { if (-not $Quiet) { Write-Host $m } else { Write-Output $m } }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"

# --- KB OriginalImages haritasi ---
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))
$kh = @{ Authorization = "Basic $pair" }
$kp = Invoke-RestMethod -Method Get -Uri "https://webservice.kruitbosch.nl/json/reply/Products?IsBike=true&ExcludeBlocked=true&IncludeAttributes=false&IncludeAdditionalImages=true&IncludeOriginalImages=true&IncludeInActive=false" -Headers $kh -TimeoutSec 300
$kbOrig = @{}
foreach ($p in $kp.Products) { $o = @($p.OriginalImages | Where-Object { "$_".Trim() }); if ($o.Count -gt 1) { $kbOrig["$($p.ProductCode)".Trim()] = $o } }
Log "KB ek-resimli urun: $($kbOrig.Count)"

# --- Shopify token ---
$sb = @{ grant_type = 'client_credentials'; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $tok }

# --- tek-resimli aktif urunler (id + ilk varyant sku) ---
$targets = @(); $after = $null
do {
    $aft = if ($after) { ', after:\"' + $after + '\"' } else { '' }
    $q = '{ "query": "{ products(first:100, query:\"status:active\"' + $aft + '){ pageInfo{hasNextPage endCursor} edges{node{ legacyResourceId images(first:3){edges{node{id}}} variants(first:1){edges{node{sku}}} }} } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($q)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
    foreach ($e in $r.data.products.edges) {
        if (@($e.node.images.edges).Count -le 1) {
            $sku = "$($e.node.variants.edges[0].node.sku)".Trim()
            if ($sku -and $kbOrig.ContainsKey($sku)) { $targets += [PSCustomObject]@{ id = $e.node.legacyResourceId; sku = $sku; imgs = $kbOrig[$sku] } }
        }
    }
    $after = if ($r.data.products.pageInfo.hasNextPage) { $r.data.products.pageInfo.endCursor } else { $null }
} while ($after)
Log "hedef (tek-resimli + KB ek-resmi olan): $($targets.Count)"

$ok = 0; $added = 0; $err = 0; $i = 0
foreach ($t in $targets) {
    $i++; if ($Limit -gt 0 -and $i -gt $Limit) { break }
    # ana gorunumu (OriginalImages[0]) ATLA - mevcut ana resimle ayni; [1..]'i ekle
    $extra = @($t.imgs | Select-Object -Skip 1)
    if (-not $extra.Count) { continue }
    if ($DryRun) { Log "[DRY] $($t.sku): +$($extra.Count) resim -> $($extra[0])"; continue }
    # src ile ekleme 422 veriyor (cdn.kruitbosch.nl hotlink korumali, Shopify fetcher cekemiyor).
    # COZUM: resmi BEN indirip base64 attachment olarak yukle (Shopify fetcher atlanir).
    foreach ($src in $extra) {
        try {
            $wc = New-Object System.Net.WebClient
            $bytes = $wc.DownloadData("$src".Trim()); $wc.Dispose()
            $b64 = [Convert]::ToBase64String($bytes)
            $fname = ("$src".Trim() -split '/')[-1]
            $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products/$($t.id)/images.json" -Headers $h -Body (@{ image = @{ attachment = $b64; filename = $fname } } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 90
            $added++
            Start-Sleep -Milliseconds 350
        } catch { $err++; Log "  [HATA] $($t.sku) $(($src -split '/')[-1]): $($_.Exception.Message)" }
    }
    $ok++
    Start-Sleep -Milliseconds 250
}
Log "resim-zenginlestirme: islenen urun $ok | eklenen resim $added | hata $err"
exit 0
