# Tum urunlerin aciklamasina duzgun HTML "Specificaties" tablosu ekler
# Kaynak: urunlerin specs.* metafieldlari. Mevcut tanitim metni korunur (tablo isareti ile degistirilir).
# Idempotent: tablosu ayni olan urunlere yazmaz. weekly_discovery.ps1 sonunda -Quiet ile cagrilir
# (yeni import edilen urunler tablosuz kalmasin diye - kullanici istegi 2026-07-06).
param([switch]$Quiet)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
function Log($m) { if (-not $Quiet) { Write-Host $m } else { Write-Output $m } }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# gosterim sirasi ve Hollandaca etiketler
$labels = [ordered]@{
    'brand' = 'Merk'; 'model' = 'Model'; 'model_year' = 'Modeljaar'
    'color_description' = 'Kleur'; 'basic_color' = 'Basiskleur'
    'frametype' = 'Frametype'; 'framesize' = 'Framehoogte (cm)'; 'material' = 'Framemateriaal'
    'wheelsize' = 'Wielmaat (inch)'; 'gears' = 'Versnellingen'
    'gearsystem_rear_brand' = 'Versnellingssysteem merk'; 'gearsystem_rear_model' = 'Versnellingssysteem'; 'gearsystem_rear_type' = 'Versnellingssysteem type'
    'brake_system_front_brand' = 'Rem voor (merk)'; 'brake_system_front_type' = 'Rem voor (type)'
    'primary_brake_system_rear_model' = 'Rem achter'; 'primary_brake_system_rear_type' = 'Rem achter (type)'
    'weight_netto' = 'Gewicht (kg)'; 'elo_bike_type' = 'E-bike type'
    # NOT: 'article_number' (Artikelnummer) tablodan cikarildi (2026-07-07) - artik baslik altinda
    # temanin 'codes' blogu ile SECILEN VARYANTIN SKU'su olarak dinamik gosteriliyor (bkz. product.json codes blok).
}
$marker = '<!-- specs-table -->'

$updated = 0; $skipped = 0; $same = 0
$cursor = $null
do {
    $after = if ($cursor) { ', after: \"' + $cursor + '\"' } else { '' }
    $gql = '{ "query": "query { products(first: 100, query: \"status:active OR status:draft\"' + $after + ') { pageInfo { hasNextPage endCursor } edges { node { legacyResourceId bodyHtml metafields(first: 40, namespace: \"specs\") { edges { node { key value } } } } } } }" }'
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body $gql -ContentType 'application/json' -TimeoutSec 60
    $pg = $r.data.products
    foreach ($e in $pg.edges) {
        $n = $e.node
        $mf = @{}
        foreach ($m in $n.metafields.edges) { $mf[$m.node.key] = $m.node.value }
        if (-not $mf.Count) { $skipped++; continue }
        $rows = ''
        foreach ($k in $labels.Keys) {
            if ($mf.ContainsKey($k) -and "$($mf[$k])".Trim()) {
                # U+FFFD (bozuk kaynak karakteri) temizle - Shopify bunu '?'ye cevirip sonsuz yeniden-yazmaya yol acar
                $raw = ("$($mf[$k])".Trim() -replace "$([char]0xFFFD)", '') -replace '\s{2,}', ' '
                $v = [System.Net.WebUtility]::HtmlEncode($raw.Trim())
                $rows += "<tr><td><strong>$($labels[$k])</strong></td><td>$v</td></tr>"
            }
        }
        if (-not $rows) { $skipped++; continue }
        $table = $marker + '<h3>Specificaties</h3><table class="specs-table" style="width:100%;border-collapse:collapse">' + $rows + '</table>'
        $body = "$($n.bodyHtml)"
        if ($body -match [regex]::Escape($marker)) { $body = ($body -split [regex]::Escape($marker))[0] }
        $newBody = ($body.Trim() + "`n" + $table).Trim()
        # karsilastirma: Shopify entity'leri litere cevirip saklar (&#233; -> e-aksan) - iki tarafi da decode et,
        # yoksa aksanli 43 urun her kosuda "farkli" gorunup bosuna yeniden yazilir
        $normNew = [System.Net.WebUtility]::HtmlDecode(($newBody -replace '>\s+<','><'))
        $normCur = [System.Net.WebUtility]::HtmlDecode(("$($n.bodyHtml)".Trim() -replace '>\s+<','><'))
        if ($normNew -eq $normCur) { $same++; continue }
        for ($try = 1; $try -le 3; $try++) {
            try {
                $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($n.legacyResourceId).json" -Headers $h -Body (@{ product = @{ id = [long]$n.legacyResourceId; body_html = $newBody } } | ConvertTo-Json -Depth 3) -ContentType 'application/json' -TimeoutSec 60
                $updated++; break
            } catch { $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }; if ($code -eq 429 -and $try -lt 3) { Start-Sleep -Seconds 2 } else { break } }
        }
        Start-Sleep -Milliseconds 450
    }
    if (-not $Quiet) { Write-Host "guncellenen: $updated | ayni (atlandi): $same | specs yok: $skipped" }
    $cursor = $pg.pageInfo.endCursor
    Start-Sleep -Milliseconds 400
} while ($pg.pageInfo.hasNextPage)
Log "DONE. tablo eklenen: $updated | ayni (atlandi): $same | atlanan (specs yok): $skipped"
