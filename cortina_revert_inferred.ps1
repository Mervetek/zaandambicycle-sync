# Tahminle (motor+konum kurali) yazilan Cortina akü/lader seceneklerini GERI ALIR.
# Sebep: kural model yiline gore guvenilmez (E-Tide 2026 Bosch, eski Bafang - portal ekrani kanitladi).
# Islem: orijinal 40'lik plan (backup) DISINDAKI tum aktif Cortina e-bike'larda battery/charger_options = "[]".
# Sonra build_cortina_options RESTORE edilmis 40'lik planla kosulur -> sadece dogrulanmis 40 secici kalir.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$d = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$sb=@{grant_type="client_credentials";client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json
$token=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h=@{"X-Shopify-Access-Token"=$token}
function GQL($q,$v){ $b=@{query=$q;variables=$v}|ConvertTo-Json -Depth 8
  for($t=1;$t -le 5;$t++){ try { return Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60 } catch { Start-Sleep -Seconds (2*$t) } }
  throw "GQL retry tukendi" }

# orijinal 40 plan SKU'lari (backup)
$keep = New-Object System.Collections.Generic.HashSet[string]
Import-Csv "$d\cortina_secici_plan_backup.csv" | ForEach-Object { [void]$keep.Add("$($_.bike_sku)".Trim()) }
Write-Host ("korunacak (dogrulanmis 40 plan) SKU: " + $keep.Count)

# aktif Cortina e-bike'lari tara; korunacaklar disindakinden akü/lader metafield'i olanlari temizle
$q='query($c:String){ products(first:100, query:"status:active AND vendor:Cortina", after:$c){ nodes{ id title variants(first:50){nodes{sku}} bat: metafield(namespace:"specs",key:"battery_options"){value} chg: metafield(namespace:"specs",key:"charger_options"){value} } pageInfo{hasNextPage endCursor} } }'
$cursor=$null; $clear=@()
do {
  $r=GQL $q @{c=$cursor}
  foreach($p in @($r.data.products.nodes)){
    $skus=@($p.variants.nodes | ForEach-Object { "$($_.sku)".Trim() })
    if(-not ($skus[0] -cmatch '^CE')){ continue }
    $isKeep = @($skus | Where-Object { $keep.Contains($_) }).Count -gt 0
    $hasOpt = ($p.bat -and "$($p.bat.value)".Trim() -and "$($p.bat.value)" -ne '[]') -or ($p.chg -and "$($p.chg.value)".Trim() -and "$($p.chg.value)" -ne '[]')
    if(-not $isKeep -and $hasOpt){ $clear += $p.id }
  }
  $cursor=$r.data.products.pageInfo.endCursor
} while($r.data.products.pageInfo.hasNextPage)
Write-Host ("temizlenecek urun (tahmini yazim): " + $clear.Count)

$mut='mutation($m:[MetafieldsSetInput!]!){ metafieldsSet(metafields:$m){ userErrors{ message } } }'
$ok=0
for($i=0;$i -lt $clear.Count;$i+=12){
  $batch=@($clear[$i..([Math]::Min($i+11,$clear.Count-1))])
  $mfs=@()
  foreach($gid in $batch){ $mfs += @{ownerId=$gid;namespace='specs';key='battery_options';type='json';value='[]'}; $mfs += @{ownerId=$gid;namespace='specs';key='charger_options';type='json';value='[]'} }
  $rr=GQL $mut @{m=$mfs}
  $ue=@($rr.data.metafieldsSet.userErrors); if($ue.Count){ Write-Host ("uyari: " + $ue[0].message) } else { $ok+=$batch.Count }
  Start-Sleep -Milliseconds 400
}
Write-Host ("temizlenen: " + $ok)
# plani orijinale dondur
Copy-Item "$d\cortina_secici_plan_backup.csv" "$d\cortina_secici_plan.csv" -Force
Write-Host "plan orijinal 40'a dondurudu"
