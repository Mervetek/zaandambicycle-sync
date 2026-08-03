# SALT-OKUNUR: birkac kirli urunun specs.* metafield anahtar/degerlerini goster (baslik yeniden kurma icin)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $api='2024-10'
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}
# ornek kirli urunler (dry-run'dan): A-Shine, Fonk, Senz + bir merged Cortina
$titles=@('a-Shine Energy','Batavus Fonk 3 Dames BLACK','Senz Active Exclusive','CORTINA DAMES')
foreach($t in $titles){
  $q='{"query":"{ products(first:1, query:\"title:*'+($t -replace ' ','* *')+'* status:active\"){edges{node{id title vendor tags metafields(namespace:\"specs\",first:40){edges{node{key value}}}}}} }"}'
  $r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($q))
  $n=$r.data.products.edges[0].node
  if(-not $n){ Write-Host "--- '$t' bulunamadi ---"; continue }
  Write-Host ("=== {0} ===" -f $n.title)
  foreach($e in $n.metafields.edges){ $v="$($e.node.value)"; if($v.Length -gt 60){$v=$v.Substring(0,60)+'..'}; Write-Host ("   {0} = {1}" -f $e.node.key,$v) }
}
