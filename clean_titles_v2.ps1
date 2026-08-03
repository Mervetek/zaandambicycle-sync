# Canli aktif urun basliklarini tara + temizle. -Apply verilmezse KURU CALISMA (sadece onizleme).
# Kural: kuyruktaki kucuk-harf-icermeyen kod token'larini at, ALLCAPS->Title-case (InvariantCulture; Turkce-I tuzagi),
# keepUpper korunur, yil sona, tekrar model-kodu kuyrugu temizlenir. Kalite kapisi: cikinca ALLCAPS(>=3) kalirsa ATLA.
param([switch]$Apply)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $api='2024-10'
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hr=@{'X-Shopify-Access-Token'=$tok}
$hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}
$ti=[Globalization.CultureInfo]::InvariantCulture.TextInfo
$keepUpper=@('BES','BES2','BES3','MM','SD','SDFM','SDMM','DB7','AL','PT','RN3','RN5','RN7','RN8','N5','N7','N8','XL','LED','GPS','ATB','MTB','OG20','UTO','UGO','QWIC','II','III','EU','NL','V1','V2','US','DT')

function IsJunk($t){ return ($t -cnotmatch '[a-z]') }   # kucuk harf yoksa kod/ALLCAPS/rakam/noktalama = cop
function CleanTitle($t){
  if(-not $t){ return $t }
  $toks=@($t -split '\s+' | Where-Object { $_ })
  # yil'i yakala (2019-2027), akistan cikar
  $year=$null
  $toks=@($toks | Where-Object { if($_ -match '^(20(1[9]|2[0-7]))$'){ $script:foundYear=$_; $false } else { $true } })
  if($script:foundYear){ $year=$script:foundYear; $script:foundYear=$null }
  # kuyruktan cop token'lari at (en az 2 token kalsin)
  while($toks.Count -gt 2 -and (IsJunk $toks[-1])){ $toks=@($toks[0..($toks.Count-2)]) }
  # token bazli Title-case
  $out=@()
  foreach($w in $toks){
    $u=$w.ToUpperInvariant()
    if($keepUpper -ccontains $u){ $out+=$u }
    elseif($w -cmatch '^[A-Z]{1,3}[0-9]' ){ $out+=$u }          # DB7, RN3, M5 gibi kod -> buyuk
    else { $out+= $ti.ToTitleCase($w.ToLowerInvariant()) }
  }
  $res=($out -join ' ')
  if($year){ $res="$res $year" }
  # ardarda ayni token tekrarini sadelestir (Metb Metb gibi)
  $res=[regex]::Replace($res,'\b(\S+)(\s+\1\b)+','$1')
  return ($res -replace '\s+',' ').Trim()
}
# kalite kapisi: keepUpper disi ALLCAPS(>=3 harf) kaldi mi?
function StillDirty($t){
  foreach($w in ($t -split '\s+')){ if($w -cmatch '^[A-Z]{3,}$' -and ($keepUpper -cnotcontains $w)){ return $true } ; if($w -cmatch '[A-Z]{2,}[./()]' -or $w -cmatch '\([A-Z0-9]') { return $true } }
  return $false
}

# tum aktif urunler
$prods=@(); $url="https://$shop/admin/api/$api/products.json?limit=250&status=active&fields=id,title,vendor"
while($url){ $resp=Invoke-WebRequest -Uri $url -Headers $hr -UseBasicParsing -TimeoutSec 60
  foreach($p in (($resp.Content|ConvertFrom-Json).products)){ $prods+=[pscustomobject]@{id=$p.id;title=$p.title;vendor="$($p.vendor)"} }
  $url=$null; if(("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"'){$url=$Matches[1]}; Start-Sleep -Milliseconds 250 }
Write-Host "aktif urun: $($prods.Count)"

$applyList=@(); $skipList=@(); $clean=0
foreach($p in $prods){
  $new=CleanTitle $p.title
  if($new -eq $p.title){ $clean++; continue }
  $dirtyBefore = StillDirty $p.title
  if(-not $dirtyBefore -and ($new -eq $p.title)){ $clean++; continue }
  if(StillDirty $new){ $skipList+=[pscustomobject]@{id=$p.id;vendor=$p.vendor;eski=$p.title;yeni=$new} }
  else { $applyList+=[pscustomobject]@{id="gid://shopify/Product/$($p.id)";vendor=$p.vendor;eski=$p.title;yeni=$new} }
}
$applyList | Export-Csv (Join-Path $PSScriptRoot "data\baslik_v2_uygula.csv") -NoTypeInformation -Encoding utf8
$skipList  | Export-Csv (Join-Path $PSScriptRoot "data\baslik_v2_atla.csv") -NoTypeInformation -Encoding utf8
Write-Host ("zaten temiz: {0} | UYGULANACAK: {1} | hala kirli/ATLA: {2}" -f $clean,$applyList.Count,$skipList.Count)
Write-Host ""
Write-Host "=== UYGULANACAK ORNEKLER (15) ==="
$applyList | Select-Object -First 15 | ForEach-Object { Write-Host ("  [{0}]`n     ESKI: {1}`n     YENI: {2}" -f $_.vendor,$_.eski,$_.yeni) }
Write-Host ""
Write-Host "=== HALA KIRLI ORNEKLER (10) ==="
$skipList | Select-Object -First 10 | ForEach-Object { Write-Host ("  ESKI: {0}`n  ->    {1}" -f $_.eski,$_.yeni) }

if($Apply){
  Write-Host ""; Write-Host "UYGULANIYOR..."
  $mut='mutation($id:ID!,$t:String!){ productUpdate(input:{id:$id, title:$t}){ userErrors{message} } }'
  $ok=0;$er=0
  foreach($r in $applyList){ $body=@{query=$mut;variables=@{id=$r.id;t=$r.yeni}}|ConvertTo-Json
    try{ $resp=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'
      if($resp.data.productUpdate.userErrors.Count){$er++}else{$ok++} }catch{$er++}
    Start-Sleep -Milliseconds 200 }
  Write-Host "DONE. uygulanan: $ok | hata: $er"
}
