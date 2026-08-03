# Model metafield'i olmayan FLAG'li Cortina basliklarini KB attrs Description'undan kur.
# Description: "{Model} {L52/H57} {Renk...} {DB7 AL MM...}" -> model=beden-oncesi, renk=beden-sonrasi kucuk-harfli tokenlar.
param([switch]$Apply)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $api='2024-10'
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}
$ti=[Globalization.CultureInfo]::InvariantCulture.TextInfo
function TC($s){ ($s -split '\s+' | ?{$_} | ForEach-Object { $ti.ToTitleCase($_.ToLowerInvariant()) }) -join ' ' }
# KB attrs yukle (BOM strip)
$kbPath=Join-Path $PSScriptRoot "data\kruitbosch_products_attrs.json"
$txt=[IO.File]::ReadAllText($kbPath); $txt=$txt.TrimStart([char]0xFEFF)
$list=@(($txt | ConvertFrom-Json))
$kb=@{}; foreach($p in $list){ $c="$($p.ProductCode)".Trim(); if($c){ $kb[$c]="$($p.Description)" } }
Write-Host "KB attrs kayit: $($kb.Count)"
$flag=Import-Csv (Join-Path $PSScriptRoot "data\baslik_v3_flag.csv") | Where-Object { $_.vendor -eq 'Cortina' }

function ParseDesc($d){
  $toks=@($d -split '\s+' | ?{$_})
  $si=-1; for($i=0;$i -lt $toks.Count;$i++){ if($toks[$i] -cmatch '^[LH]\d{2}$'){ $si=$i; break } }
  if($si -lt 1){ return $null }
  $model=($toks[0..($si-1)] -join ' ')
  $col=@(); for($j=$si+1;$j -lt $toks.Count;$j++){ if($toks[$j] -cmatch '[a-z]'){ $col+=$toks[$j] } else { break } }
  return [pscustomobject]@{ model=$model; color=($col -join ' ') }
}
$rebuild=@()
foreach($f in $flag){
  $q='{"query":"{ product(id:\"'+$f.id+'\"){ variants(first:3){edges{node{sku}}} } }"}'
  $r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($q))
  $skus=@($r.data.product.variants.edges | ForEach-Object { "$($_.node.sku)".Trim() } | ?{$_})
  $desc=''; foreach($s in $skus){ if($kb.ContainsKey($s)){ $desc=$kb[$s]; break } }
  if(-not $desc){ Write-Host "KB'de yok: $($f.eski) [$($skus -join ',')]"; continue }
  $pd=ParseDesc $desc; if(-not $pd){ Write-Host "parse edilemedi: $desc"; continue }
  $g=''; if($f.eski -imatch '\b(Dames|Heren|Meisjes|Jongens)\b'){ $g=$ti.ToTitleCase($Matches[1].ToLowerInvariant()) }
  $yr=''; if($f.eski -match '\b(20(1[9]|2[0-7]))\b'){ $yr=$Matches[1] }
  $new="Cortina $(TC $pd.model) $g"; if($yr){ $new="$new $yr" }; if($pd.color){ $new="$new - $(TC $pd.color)" }
  $new=($new -replace '\s+',' ').Trim()
  $rebuild+=[pscustomobject]@{id=$f.id;eski=$f.eski;yeni=$new}
}
Write-Host ""; Write-Host "KURULACAK: $($rebuild.Count)"
$rebuild | ForEach-Object { Write-Host ("   ESKI: {0}`n   YENI: {1}" -f $_.eski,$_.yeni) }
if($Apply){
  $mut='mutation($id:ID!,$t:String!){ productUpdate(input:{id:$id, title:$t}){ userErrors{message} } }'
  $ok=0;$er=0
  foreach($r in $rebuild){ $body=@{query=$mut;variables=@{id=$r.id;t=$r.yeni}}|ConvertTo-Json
    try{ $resp=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'; if($resp.data.productUpdate.userErrors.Count){$er++}else{$ok++} }catch{$er++}
    Start-Sleep -Milliseconds 180 }
  Write-Host "DONE. uygulanan: $ok | hata: $er"
}
