# baslik_uygulanan.csv'deki temiz basliklari uygular (idempotent: ayni basligi tekrar yazmak zararsiz).
# 2026-07-07 baslik temizligi (madde 3). Yedek: eski basliklar CSV'de.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}
$rows=Import-Csv "$env:USERPROFILE\Desktop\claude\ZaandamBicycle\data\baslik_uygulanan.csv"
function Dedup($y){ if($y -notmatch ' - '){return $y}; $p=$y -split ' - ',2; $colW=@($p[1] -split '\s+'); $left=@($p[0] -split '\s+' | Where-Object { $colW -notcontains $_ }); return (($left -join ' ')+' - '+$p[1]) }
$mut='mutation($id:ID!,$t:String!){ productUpdate(input:{id:$id, title:$t}){ product{id title} userErrors{message} } }'
$ok=0; $err=0
foreach($r in $rows){
  $y=Dedup $r.yeni; if(-not $y){ continue }
  $body=@{query=$mut; variables=@{id=$r.id; t=$y}} | ConvertTo-Json
  for($try=1;$try -le 3;$try++){
    try{ $resp=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/2024-10/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'
      if($resp.data.productUpdate.userErrors.Count){ $err++ } else { $ok++ }; break
    }catch{ if($try -lt 3){ Start-Sleep -Seconds 2 } else { $err++ } }
  }
  Start-Sleep -Milliseconds 250
}
Write-Output "DONE. uygulanan: $ok | hata: $err"
