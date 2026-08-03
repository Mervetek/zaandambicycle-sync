# SALT-OKUNUR: FLAG'li Cortina urunlerinin SKU'sunu al -> KB katalogda model adini bul (baslik kurtarma icin)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $api='2024-10'
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}
$flag=Import-Csv (Join-Path $PSScriptRoot "data\baslik_v3_flag.csv") | Where-Object { $_.vendor -eq 'Cortina' }
Write-Host "FLAG Cortina: $($flag.Count)"
# KB raw yukle
$kbPath=Join-Path $PSScriptRoot "data\kruitbosch_products_raw.json"
$kb=@{}
if(Test-Path $kbPath){
  $raw=(Get-Content $kbPath -Raw | ConvertFrom-Json)
  $list = if($raw.Products){ $raw.Products } else { $raw }
  foreach($p in $list){ $c="$($p.ProductCode)".Trim(); if($c){ $kb[$c]=$p } }
  Write-Host "KB katalog kayit: $($kb.Count)"
  # ornek KB alanlari
  $one=$list[0]; Write-Host ("KB ornek alanlar: {0}" -f (($one.PSObject.Properties.Name) -join ', '))
} else { Write-Host "KB raw YOK: $kbPath" }
Write-Host ""
foreach($f in $flag){
  $id=$f.id
  $q='{"query":"{ product(id:\"'+$id+'\"){ title variants(first:3){edges{node{sku}}} } }"}'
  $r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($q))
  $skus=@($r.data.product.variants.edges | ForEach-Object { "$($_.node.sku)".Trim() } | Where-Object {$_})
  $desc=''; $found=''
  foreach($s in $skus){ if($kb.ContainsKey($s)){ $found=$s; $desc="$($kb[$s].Description)"; break } }
  Write-Host ("[{0}]`n   SKU: {1}`n   KB-eslesme: {2} -> Description: {3}" -f $f.eski, ($skus -join ','), $found, $desc)
}
