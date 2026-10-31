# Accell (Batavus & Sparta) urunlerine akan glow efektli stok uyarisi ekler.
# Firma tarafinda siparis sistemi sorunlu - musteri satin almadan once stok sormali.
# 1) Mevcut statik rich-text "Let op" bolumunu devre disi birakir
# 2) main-product section icerisine custom_liquid blok olarak animasyonlu uyari ekler
# 2026-08-15
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference = 'Stop'
$themeDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\theme"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$tid = "gid://shopify/OnlineStoreTheme/196327965059"

# ================= AKAN GLOW EFEKTLI UYARI LIQUID =================
$warningLiquid = @'
<style>
  @keyframes accell-glow-sweep {
    0%   { background-position: -300px 0; }
    100% { background-position: 700px 0; }
  }
  @keyframes accell-icon-pulse {
    0%, 100% { transform: scale(1); }
    50%      { transform: scale(1.15); }
  }
  .accell-warn {
    position: relative;
    border: 2px solid #ea580c;
    border-radius: 10px;
    background: linear-gradient(135deg, #fff7ed 0%, #ffedd5 100%);
    padding: 14px 18px;
    margin: 12px 0 16px;
    display: flex;
    align-items: flex-start;
    gap: 12px;
    font-size: 15px;
    line-height: 1.5;
    color: #7c2d12;
    overflow: hidden;
  }
  .accell-warn::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    background: linear-gradient(
      90deg,
      transparent 0%,
      rgba(251,146,60,.25) 25%,
      rgba(234,88,12,.35) 50%,
      rgba(251,146,60,.25) 75%,
      transparent 100%
    );
    background-size: 300px 100%;
    background-repeat: no-repeat;
    animation: accell-glow-sweep 2.5s ease-in-out infinite;
    pointer-events: none;
    border-radius: 8px;
  }
  .accell-warn .aw-icon {
    font-size: 24px;
    flex-shrink: 0;
    animation: accell-icon-pulse 1.8s ease-in-out infinite;
    position: relative;
    z-index: 1;
  }
  .accell-warn .aw-body {
    position: relative;
    z-index: 1;
  }
  .accell-warn a {
    color: #ea580c;
    font-weight: 700;
    text-decoration: underline;
  }
  .accell-warn strong {
    color: #9a3412;
  }
</style>
<div class="accell-warn">
  <span class="aw-icon">&#9888;&#65039;</span>
  <div class="aw-body">
    <strong>Let op:</strong> Neem alstublieft v&oacute;&oacute;r aankoop contact met ons op om te informeren of dit product op voorraad is.
    <br>Bel ons gerust op <a href="tel:+31756175839">075 617 5839</a> of <a href="/pages/contact">neem contact op &rarr;</a>
  </div>
</div>
'@

# ================= SHOPIFY TOKEN =================
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

function StripComment($raw) {
    if ($raw -match '^(?s)\s*/\*.*?\*/\s*(.*)$') { return $Matches[1] }
    return $raw
}

# ================= HER IKI TEMPLATE'I GUNCELLE =================
$templates = @('templates/product.batavus.json', 'templates/product.sparta.json')
$filesToUpload = @()

foreach ($tmpl in $templates) {
    Write-Host "Processing: $tmpl"

    # Shopify'dan guncel template'i cek
    $query = "{ theme(id: `"gid://shopify/OnlineStoreTheme/196327965059`") { files(filenames: [`"$tmpl`"], first: 1) { nodes { filename body { ... on OnlineStoreThemeFileBodyText { content } } } } } }"
    $body = @{ query = $query } | ConvertTo-Json
    $r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
    $content = $r.data.theme.files.nodes[0].body.content

    $pJson = (StripComment $content) | ConvertFrom-Json

    # 1) Eski statik rich-text uyarisini devre disi birak
    $sections = $pJson.sections
    if ($sections.PSObject.Properties['section_rich_text_AewfVU']) {
        $sections.section_rich_text_AewfVU | Add-Member -NotePropertyName 'disabled' -NotePropertyValue $true -Force
        Write-Host "  Disabled old static rich-text warning"
    }

    # 2) main-product icerisine custom_liquid blok ekle/guncelle
    $mainProduct = $sections.'main-product'
    $blockId = 'custom_liquid_AccellWarn'

    if (-not $mainProduct.blocks.PSObject.Properties[$blockId]) {
        $mainProduct.blocks | Add-Member -NotePropertyName $blockId -NotePropertyValue ([PSCustomObject]@{
            type = "custom_liquid"
            settings = [PSCustomObject]@{ custom_liquid = $warningLiquid }
        })
        Write-Host "  Added AccellWarn block"
    } else {
        $mainProduct.blocks.$blockId.settings.custom_liquid = $warningLiquid
        Write-Host "  Updated AccellWarn block"
    }

    # block_order'a title blogundan hemen sonra ekle
    $order = [System.Collections.ArrayList]@($mainProduct.block_order)
    if ($order -notcontains $blockId) {
        $titleIdx = $order.IndexOf('c7259cb9-7235-4028-b6df-3a68077fed80')
        if ($titleIdx -ge 0) {
            $order.Insert($titleIdx + 1, $blockId)
        } else {
            $order.Insert(0, $blockId)
        }
        $mainProduct.block_order = @($order)
        Write-Host "  Added to block_order"
    }

    $pOut = $pJson | ConvertTo-Json -Depth 50

    $localPath = Join-Path $themeDir ($tmpl -replace '/', '__')
    Copy-Item $localPath "$localPath.bak" -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText("$localPath.new", $pOut, [Text.UTF8Encoding]::new($false))

    $filesToUpload += @{ filename = $tmpl; body = @{ type = 'TEXT'; value = $pOut } }
    Write-Host "  Ready`n"
}

# ================= Shopify'a yaz =================
$mutation = 'mutation UpsertFiles($themeId: ID!, $files: [OnlineStoreThemeFilesUpsertFileInput!]!) { themeFilesUpsert(themeId: $themeId, files: $files) { upsertedThemeFiles { filename } userErrors { field message } } }'
$body = @{ query = $mutation; variables = @{ themeId = $tid; files = $filesToUpload } } | ConvertTo-Json -Depth 12
$r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
if ($r.errors) { Write-Host "GRAPHQL HATA: $($r.errors[0].message)"; exit 1 }
$ue = @($r.data.themeFilesUpsert.userErrors)
if ($ue.Count) { Write-Host "USER ERROR: $($ue | ForEach-Object { "$($_.field): $($_.message)" })"; exit 1 }
$written = @($r.data.themeFilesUpsert.upsertedThemeFiles)
Write-Host "YAZILDI: $($written.Count) dosya -> $(($written | ForEach-Object { $_.filename }) -join ', ')"
