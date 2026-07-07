# Aktif ama Online Store'da yayinsiz urunleri Online Store + POS kanallarina yayinlar.
# Kok neden: 5 Temmuz politika degisikliginde taslaklar ACTIVE yapildi ama status degisikligi
# kanala YAYINLAMAZ (publishablePublish gerekir) - 492 urun vitrinde 404 idi (2026-07-06 tespiti).
# Idempotent: yalnizca publishedOnPublication=false olanlara dokunur.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$envFile = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\sync.env"
$cfg = @{}; Get-Content $envFile | ForEach-Object { if ($_ -cmatch '^([^=]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] } }
$shop = $cfg.SHOPIFY_SHOP; $api = "2024-10"
$sb = @{ grant_type="client_credentials"; client_id=$cfg.SHOPIFY_CLIENT_ID; client_secret=$cfg.SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
function GQL($q,$v){
    $b = @{ query=$q; variables=$v } | ConvertTo-Json -Depth 8
    Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
}
$osPub  = "gid://shopify/Publication/338868208003"   # Online Store
$posPub = "gid://shopify/Publication/338868240771"   # Point of Sale

# 1) yayinsiz aktifleri topla
$q = 'query($p:ID!,$c:String){ products(first:250, query:"status:active", after:$c){ nodes{ id title publishedOnPublication(publicationId:$p) } pageInfo{ hasNextPage endCursor } } }'
$cursor = $null; $targets = @()
do {
    $r = GQL $q @{ p=$osPub; c=$cursor }
    if ($r.errors) { Write-Host ("TARAMA HATA: " + $r.errors[0].message); exit 1 }
    $targets += @($r.data.products.nodes | Where-Object { -not $_.publishedOnPublication })
    $pi = $r.data.products.pageInfo; $cursor = $pi.endCursor
} while ($pi.hasNextPage)
Write-Host ("Yayinlanacak: " + $targets.Count + " urun")
if ($targets.Count -eq 0) { Write-Host "Is yok."; exit 0 }

# 2) tek tek yayinla (throttle: her 10 istekte kisa bekleme)
$mut = 'mutation($id:ID!,$input:[PublicationInput!]!){ publishablePublish(id:$id, input:$input){ userErrors{ field message } } }'
$ok = 0; $err = 0; $i = 0
foreach ($t in $targets) {
    $i++
    $r = GQL $mut @{ id=$t.id; input=@(@{publicationId=$osPub}, @{publicationId=$posPub}) }
    $ue = @($r.data.publishablePublish.userErrors)
    if ($r.errors -or $ue.Count) {
        $err++
        $msg = if ($r.errors) { $r.errors[0].message } else { $ue[0].message }
        Write-Host ("  HATA [" + $t.title + "]: " + $msg)
        if ($msg -cmatch 'Throttled') { Start-Sleep -Seconds 5 }
    } else { $ok++ }
    if ($i % 10 -eq 0) { Start-Sleep -Milliseconds 600 }
    if ($i % 100 -eq 0) { Write-Host ("  ... " + $i + "/" + $targets.Count) }
}
Write-Host ("BITTI: yayinlanan=" + $ok + " hata=" + $err)

# 3) dogrulama
$cursor = $null; $left = 0
do {
    $r = GQL $q @{ p=$osPub; c=$cursor }
    $left += @($r.data.products.nodes | Where-Object { -not $_.publishedOnPublication }).Count
    $pi = $r.data.products.pageInfo; $cursor = $pi.endCursor
} while ($pi.hasNextPage)
Write-Host ("DOGRULAMA: hala yayinsiz aktif = " + $left)
