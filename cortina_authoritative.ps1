# Cortina akü/şarj - OTORİTER kurulum (portal samenstellen ekranlarindan dogrulanan kural).
# Kural: motor markasi (SD/Bosch) x akü konumu (tasiyici/entegre). Ekranlarla teyitli 3 aile:
#   SD+tasiyici    -> CSDACCU300/400/500      + CSDLADER2A/4A
#   SD+entegre     -> CSDACCUDT400/500        + CSDLADER2A/4A
#   Bosch+tasiyici -> CBO3ACCU400/500         + CBOLADER2ALOS/4ALOS
# Bosch+entegre (yon N/HN belirsiz) ve motor='?' (E-Lett) ERTELENDI - bu script'te YOK.
# Adimlar: (1) eksik aksesuar urunlerini olustur + katalog+ccode csv'ye ekle, (2) plani 60 bisiklet icin kur.
# Sonra build_cortina_options.ps1 kosulur.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$d=Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"; $loc=118973399427
$sb=@{grant_type="client_credentials";client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json
$token=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h=@{"X-Shopify-Access-Token"=$token}
function REST($m,$p,$b){ $u="https://$shop/admin/api/$api/$p"; for($t=1;$t -le 5;$t++){ try{ if($null -ne $b){ return Invoke-RestMethod -Method $m -Uri $u -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes(($b|ConvertTo-Json -Depth 10))) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90 } else { return Invoke-RestMethod -Method $m -Uri $u -Headers $h -TimeoutSec 90 } } catch { $c=try{[int]$_.Exception.Response.StatusCode}catch{0}; if($c -eq 429 -or $c -ge 500){ Start-Sleep -Seconds (2*$t) } else { throw } } }; throw "REST retry" }
function GQL($q,$v){ $b=@{query=$q;variables=$v}|ConvertTo-Json -Depth 10; for($t=1;$t -le 5;$t++){ try{ return Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($b)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90 } catch { Start-Sleep -Seconds (2*$t) } }; throw "GQL retry" }
$osPub="gid://shopify/Publication/338868208003"; $posPub="gid://shopify/Publication/338868240771"

# --- KB aksesuar verisi (advies/EAN/image) ---
$accRaw = @((ConvertFrom-Json -InputObject (Get-Content "$d\kruitbosch_accessories_raw.json" -Raw -Encoding UTF8)) | ForEach-Object { $_ })
$accInfo=@{}; foreach($a in $accRaw){ $accInfo["$($a.ProductCode)".Trim()]=@{ ad="$($a.Description)".Trim(); ean="$($a.EANCode)".Trim(); adv=[double]$a.RecommendedSalesPrice; img="$($a.Image)".Trim() } }

# --- taze stok (yeni kodlar dahil) ---
$kh=@{ Authorization="Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:KRUITBOSCH_USERNAME):$($env:KRUITBOSCH_PASSWORD)")) }
$needCodes=@('CBO3ACCU400','CBO3ACCU500','CBOLADER2ALOS','CBOLADER4ALOS')
$rs=Invoke-RestMethod -Uri "https://webservice.kruitbosch.nl/json/reply/StocksAndPrices?CustomerNumber=$($env:KRUITBOSCH_CUSTOMER)&Products=$($needCodes -join ',')&OmmitOutOfStock=false" -Headers $kh -TimeoutSec 60
$stok=@{}; foreach($s in @($rs.StocksAndPrices)){ $stok["$($s.ProductCode)".Trim()]=[int]$s.AvailabilityId }

# --- mevcut aksesuar variant_id'leri ---
$vids=@{}
$url="https://$shop/admin/api/$api/products.json?limit=250&collection_id=707890479491&fields=id,variants"
while($url){ $resp=Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
  foreach($p in (($resp.Content|ConvertFrom-Json).products)){ foreach($v in $p.variants){ $s="$($v.sku)".Trim(); if($s){$vids[$s]=1} } }
  $url=$null; if(("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"'){$url=$Matches[1]}; Start-Sleep -Milliseconds 300 }

# --- eksik aksesuar urunlerini olustur ---
$tagAcc="Accu's en Laders"
$createdCsv=@()
foreach($c in $needCodes){
    if($vids.ContainsKey($c)){ Write-Host ("zaten var: " + $c); continue }
    $i=$accInfo[$c]; if(-not $i){ Write-Host ("KB info yok: " + $c); continue }
    $qty = if($stok[$c] -in 1,2){ 10 } else { 0 }
    $prod=@{ title=$i.ad; vendor='Cortina'; status='active'; tags=$tagAcc
      variants=@(@{ sku=$c; price=("{0:0.00}" -f $i.adv); barcode=$i.ean; inventory_management='shopify' })
      images=@(@{ src=$i.img }) }
    $np=(REST 'Post' 'products.json' @{product=$prod}).product
    $iv=$np.variants[0].inventory_item_id
    $null=REST 'Post' 'inventory_levels/set.json' @{ location_id=$loc; inventory_item_id=$iv; available=$qty }
    $null=GQL 'mutation($id:ID!,$in:[PublicationInput!]!){ publishablePublish(id:$id,input:$in){ userErrors{message} } }' @{ id="gid://shopify/Product/$($np.id)"; in=@(@{publicationId=$osPub},@{publicationId=$posPub}) }
    Write-Host ("OLUSTU: " + $c + " | " + $i.ad + " | advies=" + $i.adv + " | qty=" + $qty)
    Start-Sleep -Milliseconds 400
}

# --- kruitbosch_ccode_katalog.csv'ye yeni kodlari ekle (build_cortina_options bunu okur) ---
$kat=@(Import-Csv "$d\kruitbosch_ccode_katalog.csv")
$katCodes=@($kat.code)
$addKat=@()
foreach($c in $needCodes){
    if($katCodes -contains $c){ continue }
    $i=$accInfo[$c]
    $cap=0; if($i.ad -cmatch '(\d{3,4})\s*Wh'){ $cap=[int]$Matches[1] }
    $addKat += [PSCustomObject]@{ code=$c; ad=$i.ad; kapasite_wh=$cap; ean=$i.ean; advies=$i.adv; availability=$stok[$c]; durum='A'; alis_nett='' }
}
if($addKat.Count){ ($kat + $addKat) | Export-Csv "$d\kruitbosch_ccode_katalog.csv" -NoTypeInformation -Encoding UTF8; Write-Host ("katalog'a eklendi: " + $addKat.Count) }

# --- 60 bisiklet icin plan kur (SD+tasiyici, SD+entegre, Bosch+tasiyici) ---
$arr = @((ConvertFrom-Json -InputObject (Get-Content "$d\kruitbosch_products_attrs.json" -Raw -Encoding UTF8)) | ForEach-Object { $_ })
$byCode=@{}; foreach($p in $arr){ $m=@{}; @($p.Attributes|ForEach-Object{$_})|ForEach-Object{$m[$_.Attribute]=$_.AttributeValue}; $byCode["$($p.ProductCode)".Trim()]=@{desc=$p.Description; loc="$($m['Accu locatie'])"} }
function StripDia([string]$s){ if(-not $s){return $s}; $n=$s.Normalize([Text.NormalizationForm]::FormD); return (-join ($n.ToCharArray()|Where-Object{[Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark'})) }
$RULE=@{
  'SD|tasiyici'    = @{ accu='CSDACCU300|CSDACCU400|CSDACCU500'; lader='CSDLADER2A|CSDLADER4A' }
  'SD|entegre'     = @{ accu='CSDACCUDT400|CSDACCUDT500';        lader='CSDLADER2A|CSDLADER4A' }
  'Bosch|tasiyici' = @{ accu='CBO3ACCU400|CBO3ACCU500';          lader='CBOLADER2ALOS|CBOLADER4ALOS' }
}
# aktif Cortina e-bike urunleri (temsili SKU)
$prods=@()
$url="https://$shop/admin/api/$api/products.json?limit=250&status=active&vendor=Cortina&fields=id,variants"
while($url){ $resp=Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
  foreach($p in (($resp.Content|ConvertFrom-Json).products)){ $s0="$(@($p.variants)[0].sku)".Trim(); if($s0 -cmatch '^CE'){ $prods += ,@($p.variants | ForEach-Object { "$($_.sku)".Trim() }) } }
  $url=$null; if(("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"'){$url=$Matches[1]}; Start-Sleep -Milliseconds 300 }

$rows=@(); $defer=0
foreach($skus in $prods){
    $rep=@($skus | Where-Object { $byCode.ContainsKey($_) } | Select-Object -First 1); if(-not $rep){ $rep=$skus[0] }
    $info=$byCode[$rep]; $desc=if($info){$info.desc}else{''}; $locA=if($info){StripDia $info.loc}else{''}
    $motor= if($desc -cmatch 'SDFM|SDMM'){'SD'} elseif($desc -cmatch 'AL\+? MM|DB7 AL'){'Bosch'} else {'?'}
    $carrier= if($locA -match 'chterdrager'){'tasiyici'} elseif($locA -match 'ntegreerd'){'entegre'} else {'?'}
    $key="$motor|$carrier"
    if($RULE.ContainsKey($key)){ $rows += [PSCustomObject]@{ bike_sku=$rep; accu_seti=$RULE[$key].accu; lader_seti=$RULE[$key].lader } }
    else { $defer++ }
}
Write-Host ("plan satiri (kesin 3 aile): " + $rows.Count + " | ertelenen: " + $defer)

# plana yaz (backup = dogrulanmis 40; uzerine 60'i EKLE - cakisan bike_sku'da yeni kazanir)
$base=@(Import-Csv "$d\cortina_secici_plan_backup.csv")
$cols=($base[0].PSObject.Properties.Name)
$newSkus=@($rows.bike_sku)
$merged=@($base | Where-Object { $newSkus -notcontains $_.bike_sku })  # cakisani cikar
foreach($r in $rows){ $o=[ordered]@{}; foreach($c in $cols){ $o[$c]=switch($c){'bike_sku'{$r.bike_sku}'accu_seti'{$r.accu_seti}'lader_seti'{$r.lader_seti}'magazada'{'VAR'}default{''}} }; $merged+=[PSCustomObject]$o }
$merged | Export-Csv "$d\cortina_secici_plan.csv" -NoTypeInformation -Encoding UTF8
Write-Host ("plan yazildi: " + @($merged).Count + " satir")
