# Cortina e-bike seçici kapsamini genisletir: eski-site planinda OLMAYAN aktif Cortina e-bike'lara
# motor sistemi + akü konumu KURALIYLA akü/lader setini atar ve cortina_secici_plan.csv'ye ekler.
# Kural, mevcut 40 bilinen eslemenin birebir oruntusu (tahmin degil). Sonra build_cortina_options.ps1 kosulur.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$d = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$sb = @{ grant_type="client_credentials"; client_id=$env:SHOPIFY_CLIENT_ID; client_secret=$env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }

# aksan-duyarsizlik: PS 5.1 BOM'suz okumada 'ï' bozulur; konumu ASCII'ye indir
function StripDia([string]$s){ if(-not $s){return $s}; $n=$s.Normalize([Text.NormalizationForm]::FormD); return (-join ($n.ToCharArray()|Where-Object{[Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark'})) }
# KURAL TABLOSU: "motorSig | LOC(ascii)" -> @{accu; lader}  (LOC: Geintegreerd / Achterdrager)
$RULES = @{
  'DB7 AL MM | Achterdrager'   = @{ accu='CBFACCU750|CBFACCU600|CBFACCU450'; lader='CBFLADER3ACB|CBFLADERCB' }
  'DB7 AL+ MM | Achterdrager'  = @{ accu='CBOACCU500|CBOACCU400|CBOACCU300'; lader='CBOLADER4A|CBOLADER2A' }
  'DB7 AL+ MM | Geintegreerd'  = @{ accu='CBO3ACCUDT625|CBO3ACCUDT500';      lader='CBOLADER4A|CBOLADER2A' }
  'DB7 SDFM | Achterdrager'    = @{ accu='CSDACCU500|CSDACCU400|CSDACCU300';  lader='CSDLADER4A|CSDLADER2A' }
  'DB7 SDMM | Geintegreerd'    = @{ accu='CSDACCUDT500|CSDACCUDT400';         lader='CSDLADER4A|CSDLADER2A' }
}
function MotorSig($desc){ if($desc -cmatch '(DB7|DB)\s+(SDFM|SDMM|AL\+|AL)\s*(MM)?'){ return ('DB7 ' + ($Matches[2]) + $(if($Matches[3]){' '+$Matches[3]}else{''})).Trim() } return $null }

# KB attrs: kod -> desc + Accu locatie
$arr = @((ConvertFrom-Json -InputObject (Get-Content "$d\kruitbosch_products_attrs.json" -Raw -Encoding UTF8)) | ForEach-Object { $_ })
$byCode = @{}
foreach($p in $arr){ $m=@{}; @($p.Attributes|ForEach-Object{$_})|ForEach-Object{$m[$_.Attribute]=$_.AttributeValue}; $byCode["$($p.ProductCode)".Trim()]=@{desc=$p.Description; loc="$($m['Accu locatie'])"} }

$planCodes = New-Object System.Collections.Generic.HashSet[string]
Import-Csv "$d\cortina_secici_plan.csv" | ForEach-Object { [void]$planCodes.Add("$($_.bike_sku)".Trim()) }

# mevcut aktif Cortina e-bike urunleri (temsili 1 SKU/urun)
$prods = @()
$url = "https://$shop/admin/api/$api/products.json?limit=250&status=active&vendor=Cortina&fields=id,title,variants"
while ($url) {
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
    foreach ($p in (($resp.Content | ConvertFrom-Json).products)) {
        $sku0 = "$(@($p.variants)[0].sku)".Trim()
        if ($sku0 -cmatch '^CE') { $prods += [PSCustomObject]@{ title=$p.title; skus=@($p.variants | ForEach-Object { "$($_.sku)".Trim() }) } }
    }
    $url = $null; if (("$($resp.Headers['Link'])") -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    Start-Sleep -Milliseconds 300
}
Write-Host ("aktif Cortina e-bike urun: " + $prods.Count)

$newRows = @(); $unmapped = @()
foreach ($pr in $prods) {
    # bu urun zaten planda mi? (herhangi bir variant SKU plana giriyorsa atla)
    if (@($pr.skus | Where-Object { $planCodes.Contains($_) }).Count) { continue }
    # temsili SKU: attrs'te bulunani sec
    $rep = @($pr.skus | Where-Object { $byCode.ContainsKey($_) } | Select-Object -First 1)
    if (-not $rep) { $rep = $pr.skus[0] }
    $info = $byCode[$rep]
    $desc = if ($info) { $info.desc } else { $pr.title }
    $loc  = if ($info -and $info.loc) { $info.loc } else {
        # attrs yoksa modelden cikar: Int/Integrated/Common Int/Next = Geintegreerd; digeri Achterdrager
        if ($pr.title -cmatch 'Int\b|Integrated|Geïntegreerd|Next') { 'Geïntegreerd' } else { 'Achterdrager' }
    }
    $motor = MotorSig $desc
    if (-not $motor) { $motor = MotorSig $pr.title }
    $locA = StripDia $loc
    if ($locA -match 'ntegreerd') { $locA = 'Geintegreerd' } elseif ($locA -match 'chterdrager') { $locA = 'Achterdrager' }
    $key = "$motor | $locA"
    if ($RULES.ContainsKey($key)) {
        $newRows += [PSCustomObject]@{ bike_sku=$rep; accu_seti=$RULES[$key].accu; lader_seti=$RULES[$key].lader; magazada='VAR'; kural=$key }
    } else {
        $unmapped += [PSCustomObject]@{ sku=$rep; title=$pr.title; motor=$motor; loc=$loc }
    }
}
Write-Host ("kurala eslesen (eklenecek): " + $newRows.Count + " | eslesemeyen: " + $unmapped.Count)
$newRows | Group-Object kural | Sort-Object Count -Descending | ForEach-Object { Write-Host ("   [" + $_.Count + "] " + $_.Name) }
if ($unmapped.Count) { Write-Host "=== ESLESEMEYEN (elle bakilacak) ==="; $unmapped | ForEach-Object { Write-Host ("   " + $_.sku + " | motor=" + $_.motor + " | loc=" + $_.loc + " | " + $_.title) }; $unmapped | Export-Csv "$d\cortina_kural_disi.csv" -NoTypeInformation -Encoding UTF8 }

# plana ekle (kural kolonu haric sema uyumlu) - once mevcut semayi al
$existing = Import-Csv "$d\cortina_secici_plan.csv"
$cols = ($existing[0].PSObject.Properties.Name)
$toAppend = foreach($r in $newRows){
    $o = [ordered]@{}
    foreach($c in $cols){ $o[$c] = switch($c){ 'bike_sku'{$r.bike_sku} 'accu_seti'{$r.accu_seti} 'lader_seti'{$r.lader_seti} 'magazada'{'VAR'} default{''} } }
    [PSCustomObject]$o
}
if ($toAppend) {
    Copy-Item "$d\cortina_secici_plan.csv" "$d\cortina_secici_plan_backup.csv" -Force
    ($existing + $toAppend) | Export-Csv "$d\cortina_secici_plan.csv" -NoTypeInformation -Encoding UTF8
    Write-Host ("plana eklendi: " + @($toAppend).Count + " satir (yedek: cortina_secici_plan_backup.csv)")
}
