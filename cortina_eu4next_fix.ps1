# DUZELTME: E-U4 Next portal ekrani YATAY (HN) akü gosteriyor (CBO3ACCUDT500HN/625HN),
# dikey (N) DEGIL. Onceki dikey atama yanlisti. HN urunlerini olustur, E-U4 Next plan satirlarini HN'e cevir.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$d=Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"; $loc=118973399427
$sb=@{grant_type="client_credentials";client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json
$token=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h=@{"X-Shopify-Access-Token"=$token}
function REST($m,$p,$b){ $u="https://$shop/admin/api/$api/$p"; for($t=1;$t -le 5;$t++){ try{ if($null -ne $b){ return Invoke-RestMethod -Method $m -Uri $u -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes(($b|ConvertTo-Json -Depth 10))) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90 } else { return Invoke-RestMethod -Method $m -Uri $u -Headers $h -TimeoutSec 90 } } catch { $c=try{[int]$_.Exception.Response.StatusCode}catch{0}; if($c -eq 429 -or $c -ge 500){Start-Sleep -Seconds (2*$t)}else{throw} } }; throw "REST retry" }
function GQL($q,$v){ $b=@{query=$q;variables=$v}|ConvertTo-Json -Depth 10; for($t=1;$t -le 5;$t++){ try{ return Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90 } catch { Start-Sleep -Seconds (2*$t) } }; throw "GQL retry" }
$osPub="gid://shopify/Publication/338868208003"; $posPub="gid://shopify/Publication/338868240771"

$accRaw=@((ConvertFrom-Json -InputObject (Get-Content "$d\kruitbosch_accessories_raw.json" -Raw -Encoding UTF8))|ForEach-Object{$_})
$accInfo=@{}; foreach($a in $accRaw){ $accInfo["$($a.ProductCode)".Trim()]=@{ad="$($a.Description)".Trim();ean="$($a.EANCode)".Trim();adv=[double]$a.RecommendedSalesPrice;img="$($a.Image)".Trim()} }
$kh=@{Authorization="Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)"))}
$need=@('CBO3ACCUDT500HN','CBO3ACCUDT625HN')
$rs=Invoke-RestMethod -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($need -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
$stok=@{}; foreach($s in @($rs.StocksAndPrices)){ $stok["$($s.ProductCode)".Trim()]=[int]$s.AvailabilityId }
$have=@{}; $url="https://$shop/admin/api/$api/products.json?limit=250&collection_id=707890479491&fields=variants"
while($url){ $resp=Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60; foreach($p in (($resp.Content|ConvertFrom-Json).products)){ foreach($v in $p.variants){ $s="$($v.sku)".Trim(); if($s){$have[$s]=1} } }; $url=$null; if($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"'){$url=$Matches[1]}; Start-Sleep -Milliseconds 300 }
foreach($c in $need){
  if($have.ContainsKey($c)){ Write-Host ("zaten var: "+$c); continue }
  $i=$accInfo[$c]; if(-not $i){ Write-Host ("KB info yok: "+$c); continue }
  $qty=if($stok[$c] -in 1,2){10}else{0}
  $np=(REST 'Post' 'products.json' @{product=@{title=$i.ad;vendor='Cortina';status='active';tags="Accu's en Laders";variants=@(@{sku=$c;price=("{0:0.00}" -f $i.adv);barcode=$i.ean;inventory_management='shopify'});images=@(@{src=$i.img})}}).product
  $null=REST 'Post' 'inventory_levels/set.json' @{location_id=$loc;inventory_item_id=$np.variants[0].inventory_item_id;available=$qty}
  $null=GQL 'mutation($id:ID!,$in:[PublicationInput!]!){publishablePublish(id:$id,input:$in){userErrors{message}}}' @{id="gid://shopify/Product/$($np.id)";in=@(@{publicationId=$osPub},@{publicationId=$posPub})}
  Write-Host ("OLUSTU: "+$c+" | "+$i.ad+" | advies="+$i.adv+" | qty="+$qty); Start-Sleep -Milliseconds 400
}
$kat=@(Import-Csv "$d\kruitbosch_ccode_katalog.csv"); $kc=@($kat.code); $add=@()
foreach($c in $need){ if($kc -contains $c){continue}; $i=$accInfo[$c]; $cap=0; if($i.ad -cmatch '(\d{3,4})'){$cap=[int]$Matches[1]}; $add+=[PSCustomObject]@{code=$c;ad=$i.ad;kapasite_wh=$cap;ean=$i.ean;advies=$i.adv;availability=$stok[$c];durum='A';alis_nett=''} }
if($add.Count){ ($kat+$add)|Export-Csv "$d\kruitbosch_ccode_katalog.csv" -NoTypeInformation -Encoding UTF8; Write-Host ("katalog +"+$add.Count) }

# E-U4 Next plan satirlarini N -> HN cevir
$plan=@(Import-Csv "$d\cortina_secici_plan.csv")
$arr=@((ConvertFrom-Json -InputObject (Get-Content "$d\kruitbosch_products_attrs.json" -Raw -Encoding UTF8))|ForEach-Object{$_})
$descByCode=@{}; foreach($p in $arr){ $descByCode["$($p.ProductCode)".Trim()]="$($p.Description)" }
$fixed=0
foreach($row in $plan){
  $desc="$($descByCode[$row.bike_sku])"
  if($desc -cmatch 'Next' -and "$($row.accu_seti)" -eq 'CBO3ACCUDT500N|CBO3ACCUDT625N'){
    $row.accu_seti='CBO3ACCUDT500HN|CBO3ACCUDT625HN'; $fixed++
  }
}
$plan|Export-Csv "$d\cortina_secici_plan.csv" -NoTypeInformation -Encoding UTF8
Write-Host ("E-U4 Next plan satiri N->HN duzeltilen: "+$fixed)
