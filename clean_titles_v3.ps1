# Kirli bisiklet basliklarini specs metafield'lariyla YENIDEN KUR. -Apply yoksa kuru calisma.
# Aksesuarlar haric. Sadece kirli (StillDirty) basliklara dokunur. model metafield'i olmayan (Cortina merged) -> FLAG (model eksik).
# Format: "{Brand} {Model} {Gender} {Yil} - {Renk}" (eksikler atlanir). Turkce-I: InvariantCulture + -cmatch.
param([switch]$Apply)
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop='8t0pzm-g1.myshopify.com'; $api='2024-10'
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hj=@{'X-Shopify-Access-Token'=$tok;'Content-Type'='application/json'}
$ti=[Globalization.CultureInfo]::InvariantCulture.TextInfo
$keepUpper=@('BES','BES2','BES3','MM','SD','SDFM','SDMM','DB7','AL','PT','RN3','RN5','RN7','RN8','N5','N7','N8','XL','LED','GPS','ATB','MTB','OG20','UTO','UGO','QWIC','II','III','V1','V2','DT')
function TC($s){ if(-not $s){return ''}
  $o=@(); foreach($w in ($s -split '\s+' | ? {$_})){ $u=$w.ToUpperInvariant()
    if($keepUpper -ccontains $u){ $o+=$u } elseif($w -cmatch '^[A-Z]{1,3}[0-9]'){ $o+=$u } else { $o+=$ti.ToTitleCase($w.ToLowerInvariant()) } }
  return ($o -join ' ') }
function IsJunk($t){ return ($t -cnotmatch '[a-z]') }
function StripJunkTail($t){ $toks=@($t -split '\s+' | ?{$_}); while($toks.Count -gt 1 -and (IsJunk $toks[-1])){ $toks=@($toks[0..($toks.Count-2)]) }; return ($toks -join ' ') }
function StillDirty($t){ foreach($w in ($t -split '\s+')){ if($w -cmatch '^[A-Z]{3,}$' -and ($keepUpper -cnotcontains $w)){return $true}; if($w -cmatch '\([A-Z0-9]' -or $w -cmatch '[A-Z]{2,}[./]'){return $true} }; return $false }
$genderMap=@{ 'Women'='Dames';'Men'='Heren';'Girls'='Meisjes';'Boys'='Jongens';'Unisex'='Unisex' }

# tum aktif urunler + specs
$nodes=@(); $after=$null; $more=$true
while($more){
  $q='{"query":"{ products(first:100, query:\"status:active\"'+$(if($after){', after:\"'+$after+'\"'}else{''})+'){ pageInfo{hasNextPage endCursor} edges{node{ id title vendor tags brand:metafield(namespace:\"specs\",key:\"brand\"){value} model:metafield(namespace:\"specs\",key:\"model\"){value} yr:metafield(namespace:\"specs\",key:\"model_year\"){value} colr:metafield(namespace:\"specs\",key:\"color_description\"){value} ft:metafield(namespace:\"specs\",key:\"frametype\"){value} }} } }"}'
  $r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($q))
  if($r.errors){ Write-Host "ERR: $($r.errors.message -join '; ')"; break }
  foreach($e in $r.data.products.edges){ $nodes+=$e.node }
  $more=$r.data.products.pageInfo.hasNextPage; $after=$r.data.products.pageInfo.endCursor
}
Write-Host "aktif urun: $($nodes.Count)"

$applyList=@(); $flag=@(); $cleanN=0; $accN=0
foreach($n in $nodes){
  if("$($n.tags)" -match "Accu's en Laders"){ continue }
  $t=$n.title
  if(-not (StillDirty $t)){ $cleanN++; continue }
  # gender
  $g=''; if($t -imatch '\b(Dames|Heren|Meisjes|Jongens|Unisex)\b'){ $g=$ti.ToTitleCase($Matches[1].ToLowerInvariant()) }
  elseif($n.ft.value -and $genderMap[$n.ft.value]){ $g=$genderMap[$n.ft.value] }
  # brand + model
  $brand = if($n.brand.value){ TC $n.brand.value } else { TC ($t -split '\s+')[0] }
  $model = if($n.model.value){ $n.model.value } else { '' }
  $year = if($n.yr.value){ ($n.yr.value -replace '[^0-9]','') } else { if($t -match '\b(20(1[9]|2[0-7]))\b'){$Matches[1]}else{''} }
  # renk: metafield color_description > baslik(gender sonrasi, junk-strip)
  $color=''
  if($n.colr.value){ $color=$n.colr.value }
  else {
    $otoks=@($t -split '\s+' | ?{$_})
    $gi=-1; for($i=0;$i -lt $otoks.Count;$i++){ if($otoks[$i] -imatch '^(Dames|Heren|Meisjes|Jongens|Unisex)$'){ $gi=$i; break } }
    if($gi -ge 0){
      # 1) gender'dan hemen sonra ALLCAPS renk kosusu (VOLCANO BLACK MATT)
      $col=@(); for($j=$gi+1;$j -lt $otoks.Count;$j++){ if($otoks[$j] -cmatch '^[A-Z]{2,}$'){ $col+=$otoks[$j] } else { break } }
      if($col.Count){ $color=($col -join ' ') }
      else {
        # 2) mixed-case: junk-strip sonrasi gender sonrasi kucuk-harfli token'lar
        $st=@((StripJunkTail $t) -split '\s+' | ?{$_}); $sgi=-1; for($i=0;$i -lt $st.Count;$i++){ if($st[$i] -imatch '^(Dames|Heren|Meisjes|Jongens|Unisex)$'){ $sgi=$i; break } }
        if($sgi -ge 0 -and $sgi -lt $st.Count-1){ $rest=@($st[($sgi+1)..($st.Count-1)] | ?{ $_ -cmatch '[a-z]' -and $_ -notmatch '^(20(1[9]|2[0-7]))$' }); $color=($rest -join ' ') }
      }
    }
  }
  if(-not $model){ $flag+=[pscustomobject]@{id=$n.id;vendor=$n.vendor;eski=$t;sebep='model metafield YOK'}; continue }
  # birlestir
  $parts=@($brand,(TC $model),$g | ?{$_})
  $new=($parts -join ' ')
  if($year){ $new="$new $year" }
  if($color){ $new="$new - $(TC $color)" }
  $new=($new -replace '\s+',' ').Trim()
  $new=[regex]::Replace($new,'\b(\S+)(\s+\1\b)+','$1')  # tekrar sadeles
  if(StillDirty $new){ $flag+=[pscustomobject]@{id=$n.id;vendor=$n.vendor;eski=$t;sebep="temizlenemedi: $new"}; continue }
  if($new -eq $t){ $cleanN++; continue }
  $applyList+=[pscustomobject]@{id=$n.id;vendor=$n.vendor;eski=$t;yeni=$new}; $accN++
}
$applyList | Export-Csv (Join-Path $PSScriptRoot "data\baslik_v3_uygula.csv") -NoTypeInformation -Encoding utf8
$flag | Export-Csv (Join-Path $PSScriptRoot "data\baslik_v3_flag.csv") -NoTypeInformation -Encoding utf8
Write-Host ("temiz(dokunulmadi): {0} | YENIDEN KURULACAK: {1} | FLAG(model yok/temizlenemedi): {2}" -f $cleanN,$applyList.Count,$flag.Count)
Write-Host ""; Write-Host "=== YENIDEN KURULACAK ORNEK (18) ==="
$applyList | Select-Object -First 18 | ForEach-Object { Write-Host ("  [{0}]`n    ESKI: {1}`n    YENI: {2}" -f $_.vendor,$_.eski,$_.yeni) }
Write-Host ""; Write-Host "=== FLAG ORNEK (12) ==="
$flag | Select-Object -First 12 | ForEach-Object { Write-Host ("  [{0}] {1}  ({2})" -f $_.vendor,$_.eski,$_.sebep) }
Write-Host ""; Write-Host ("FLAG marka dagilimi:"); $flag | Group-Object vendor | Sort-Object Count -Descending | ForEach-Object { Write-Host ("   {0}: {1}" -f $_.Name,$_.Count) }

if($Apply){
  Write-Host ""; Write-Host "UYGULANIYOR..."
  $mut='mutation($id:ID!,$t:String!){ productUpdate(input:{id:$id, title:$t}){ userErrors{message} } }'
  $ok=0;$er=0
  foreach($r in $applyList){ $body=@{query=$mut;variables=@{id=$r.id;t=$r.yeni}}|ConvertTo-Json
    try{ $resp=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hj -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'; if($resp.data.productUpdate.userErrors.Count){$er++}else{$ok++} }catch{$er++}
    Start-Sleep -Milliseconds 180 }
  Write-Host "DONE. uygulanan: $ok | hata: $er"
}
