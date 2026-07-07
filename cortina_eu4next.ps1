# E-U4 Next (Bosch entegre, 11) plana ekler. Kanit: tum Bosch-entegre portal ekranlari dikey(N),
# E-U4 Next attribute profili E-Common ile ayni (Bosch Powertube entegre Smart System) - ayni N akü.
# Urunler (CBO3ACCUDT500N/625N, CBOLADER2ALOS/4ALOS) zaten mevcut; sadece plan + build_cortina.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$d=Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$sb=@{grant_type="client_credentials";client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json
$token=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h=@{"X-Shopify-Access-Token"=$token}
$arr=@((ConvertFrom-Json -InputObject (Get-Content "$d\kruitbosch_products_attrs.json" -Raw -Encoding UTF8))|ForEach-Object{$_})
$byCode=@{}; foreach($p in $arr){ $m=@{}; @($p.Attributes|ForEach-Object{$_})|ForEach-Object{$m[$_.Attribute]=$_.AttributeValue}; $byCode["$($p.ProductCode)".Trim()]=@{desc=$p.Description;loc="$($m['Accu locatie'])"} }
function StripDia([string]$s){ if(-not $s){return $s}; $n=$s.Normalize([Text.NormalizationForm]::FormD); return (-join ($n.ToCharArray()|Where-Object{[Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark'})) }
$prods=@(); $url="https://$shop/admin/api/$api/products.json?limit=250&status=active&vendor=Cortina&fields=variants"
while($url){ $resp=Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60; foreach($p in (($resp.Content|ConvertFrom-Json).products)){ $s0="$(@($p.variants)[0].sku)".Trim(); if($s0 -cmatch '^CE'){ $prods+=,@($p.variants|ForEach-Object{"$($_.sku)".Trim()}) } }; $url=$null; if($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"'){$url=$Matches[1]}; Start-Sleep -Milliseconds 300 }
$rows=@()
foreach($skus in $prods){
  $rep=@($skus|Where-Object{$byCode.ContainsKey($_)}|Select-Object -First 1); if(-not $rep){continue}
  $info=$byCode[$rep]; $desc=$info.desc; $locA=StripDia $info.loc
  $motor=if($desc -cmatch 'SDFM|SDMM'){'SD'}elseif($desc -cmatch 'AL\+? MM|DB7 AL'){'Bosch'}else{'?'}
  $carrier=if($locA -match 'ntegreerd'){'entegre'}elseif($locA -match 'chterdrager'){'tasiyici'}else{'?'}
  if($motor -eq 'Bosch' -and $carrier -eq 'entegre' -and $desc -cmatch 'Next'){
    $rows+=[PSCustomObject]@{bike_sku=$rep;accu_seti='CBO3ACCUDT500N|CBO3ACCUDT625N';lader_seti='CBOLADER2ALOS|CBOLADER4ALOS'}
  }
}
Write-Host ("E-U4 Next plan satiri: "+$rows.Count)
$plan=@(Import-Csv "$d\cortina_secici_plan.csv"); $cols=($plan[0].PSObject.Properties.Name); $ns=@($rows.bike_sku)
$merged=@($plan|Where-Object{$ns -notcontains $_.bike_sku})
foreach($r in $rows){ $o=[ordered]@{}; foreach($c in $cols){$o[$c]=switch($c){'bike_sku'{$r.bike_sku}'accu_seti'{$r.accu_seti}'lader_seti'{$r.lader_seti}'magazada'{'VAR'}default{''}}}; $merged+=[PSCustomObject]$o }
$merged|Export-Csv "$d\cortina_secici_plan.csv" -NoTypeInformation -Encoding UTF8
Write-Host ("plan yazildi: "+@($merged).Count)
