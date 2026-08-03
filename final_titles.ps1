# Son 5 kenar-durum basligi elle-dogrulanmis temiz hallerine ayarla (eski metne gore eslesir).
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $api='2024-10'
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}
$map=@{
 'VOLARE Excellent Meisjes Ink Green 25cm 2025'='Volare Excellent Meisjes 2025 - Ink Green'
 'Batavus Click (8V) L Lightarmy green 362 Dames 2022'='Batavus Click Dames 2022 - Lightarmy Green'
 'Batavus Fonk 3 (N3) L Dames 2026 - Light Silver Matt'='Batavus Fonk 3 Dames 2026 - Light Silver Matt'
 'Batavus Altura E-go Power Pro BES3 Incl. 500wh Dames 2024 - Mahonierood Velder-D Plus(Col2)(N5)'='Batavus Altura E-Go Power Pro BES3 Incl. 500Wh Dames 2024 - Mahonierood'
 'Batavus Altura E-go Power Pro BES3 Incl. 500wh Dames 2024 - Mahonierood Altura-D Pro(Col2)(N5)'='Batavus Altura E-Go Power Pro BES3 Incl. 500Wh Dames 2024 - Mahonierood'
}
$flag=Import-Csv (Join-Path $PSScriptRoot "data\baslik_v3_flag.csv")
$mut='mutation($id:ID!,$t:String!){ productUpdate(input:{id:$id, title:$t}){ userErrors{message} } }'
$ok=0;$er=0;$skip=0
foreach($f in $flag){
  $e="$($f.eski)".Trim()
  if(-not $map.ContainsKey($e)){ $skip++; continue }
  $t=$map[$e]
  $body=@{query=$mut;variables=@{id=$f.id;t=$t}}|ConvertTo-Json
  try{ $resp=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'
    if($resp.data.productUpdate.userErrors.Count){$er++; Write-Host "ERR: $($resp.data.productUpdate.userErrors.message)"}else{$ok++; Write-Host "OK: $t"} }catch{$er++}
  Start-Sleep -Milliseconds 180
}
Write-Host "DONE. uygulanan: $ok | hata: $er | eslesmeyen(atlanan): $skip"
