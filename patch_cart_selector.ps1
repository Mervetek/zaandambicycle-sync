# Varsayilan templates/product.json icindeki KULMdX (accu+lader secici) blogunu v3 ile degistirir.
#
# SORUN: varsayilan sablondaki blok v1'de kalmis. v1'in add-to-cart devralmasi sadece
#   ev.target.closest('[name="add"]') ile calisiyor; Xtra temasinin sepet butonunda
#   name="add" YOK (<button type="submit" class="overlay-buy_button">). Devralma hic
#   tetiklenmiyor -> tema kendi /cart/add'ini yapiyor -> sepete SADECE bisiklet gidiyor.
#   Ayrica v1 accuyu eski SUR ek-ucret varyanti haritasindan cozuyor; 699 haritada yok,
#   yani devralma calissa bile accu satiri sessizce dusuyordu.
# COZUM: batavus/sparta sablonlarinda 2026-08-15'ten beri canli olan v2 blogunun
#   (submit + click yakalama, gercek variant_id) varsayilan sabloma tasinmasi = v3.
#
# Kullanim:
#   pwsh -File patch_cart_selector.ps1              -> KURU CALISMA (hicbir sey yazmaz)
#   pwsh -File patch_cart_selector.ps1 -Apply       -> canli temaya PUT eder
#   pwsh -File patch_cart_selector.ps1 -Rollback <yedek.json>  -> yedegi geri yukler
param(
  [switch]$Apply,
  [string]$LiquidFile,
  [string]$Rollback
)
$ErrorActionPreference = 'Stop'

if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"; $key = 'templates/product.json'
$eu8 = [Text.UTF8Encoding]::new($false)

$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hr = @{"X-Shopify-Access-Token" = $tok}
$main = ((Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $hr).themes | Where-Object { $_.role -eq 'main' })
Write-Host ("ANA TEMA: {0} (id {1})" -f $main.name, $main.id)

function Get-Asset {
  (Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $hr).asset.value
}
function Put-Asset([string]$value) {
  $body = @{ asset = @{ key = $key; value = $value } } | ConvertTo-Json -Depth 6
  $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json" -Headers $hr -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
}

# ---- GERI ALMA ----
if ($Rollback) {
  if (-not (Test-Path $Rollback)) { throw "Yedek bulunamadi: $Rollback" }
  $bak = [IO.File]::ReadAllText($Rollback, $eu8)
  $null = $bak | ConvertFrom-Json   # gecerli mi?
  Put-Asset $bak
  Start-Sleep -Seconds 2
  $chk = Get-Asset
  Write-Host ("GERI ALINDI. canli==yedek: {0}" -f ($chk.Trim() -eq $bak.Trim()))
  return
}

# ---- JSON string kacis/coz yardimcilari ----
function Escape-JsonString([string]$s) {
  $sb = [Text.StringBuilder]::new()
  foreach ($ch in $s.ToCharArray()) {
    switch ($ch) {
      '"'      { [void]$sb.Append('\"'); continue }
      '\'      { [void]$sb.Append('\\'); continue }
      "`b"     { [void]$sb.Append('\b');  continue }
      "`f"     { [void]$sb.Append('\f');  continue }
      "`n"     { [void]$sb.Append('\n');  continue }
      "`r"     { [void]$sb.Append('\r');  continue }
      "`t"     { [void]$sb.Append('\t');  continue }
      default  {
        if ([int]$ch -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
        else { [void]$sb.Append($ch) }
      }
    }
  }
  $sb.ToString()
}

# "custom_liquid_KULMdX" nesnesindeki "custom_liquid": "..." degerinin HAM (kacisli) araligini bul
function Find-KulmdxSpan([string]$raw) {
  $blockIdx = $raw.IndexOf('"custom_liquid_KULMdX"')
  if ($blockIdx -lt 0) { throw 'custom_liquid_KULMdX blogu bulunamadi' }
  # "custom_liquid" burada ANAHTAR olmali (type degeri olan "custom_liquid" ile karismasin)
  $m = [regex]::Match($raw.Substring($blockIdx), '"custom_liquid"\s*:\s*"')
  if (-not $m.Success) { throw 'KULMdX icinde custom_liquid alani bulunamadi' }
  $q = $blockIdx + $m.Index + $m.Length - 1
  $i = $q + 1
  while ($i -lt $raw.Length) {
    $c = $raw[$i]
    if ($c -eq '\') { $i += 2; continue }
    if ($c -eq '"') { break }
    $i++
  }
  if ($i -ge $raw.Length) { throw 'custom_liquid degerinin kapanis tirnagi bulunamadi' }
  [pscustomobject]@{ Start = $q + 1; Length = $i - ($q + 1) }
}

# ---- YAMA ----
if (-not $LiquidFile) { $LiquidFile = Join-Path $PSScriptRoot "theme\kulmdx_v3.liquid" }
if (-not (Test-Path $LiquidFile)) { throw "Liquid dosyasi yok: $LiquidFile" }
$new = [IO.File]::ReadAllText($LiquidFile, $eu8) -replace "`r`n", "`n"

$raw = Get-Asset
$span = Find-KulmdxSpan $raw
$oldEsc = $raw.Substring($span.Start, $span.Length)
$old = ('"' + $oldEsc + '"' | ConvertFrom-Json)

Write-Host ""
Write-Host "--- MEVCUT CANLI BLOK ---"
Write-Host ("  uzunluk        : {0}" -f $old.Length)
Write-Host ("  var SUR (v1)   : {0}" -f ($old -match 'var SUR'))
Write-Host ("  isMainForm(v2) : {0}" -f ($old -match 'isMainForm'))
Write-Host ("  submit dinleme : {0}" -f ($old -match "addEventListener\('submit'"))
Write-Host "--- YENI BLOK ---"
Write-Host ("  uzunluk        : {0}" -f $new.Length)
Write-Host ("  var SUR        : {0}" -f ($new -match 'var SUR'))
Write-Host ("  isMainForm     : {0}" -f ($new -match 'isMainForm'))
Write-Host ("  submit dinleme : {0}" -f ($new -match "addEventListener\('submit'"))

if ($old -match 'isMainForm') { Write-Host ""; Write-Host "ZATEN YAMALI (isMainForm var) - cikiliyor"; return }
if ($old -notmatch 'var SUR') { Write-Host ""; Write-Host "BEKLENEN v1 blogu DEGIL (var SUR yok) - DUR"; return }

$patched = $raw.Substring(0, $span.Start) + (Escape-JsonString $new) + $raw.Substring($span.Start + $span.Length)

# --- dogrulamalar ---
$obj = $patched | ConvertFrom-Json                      # 1) gecerli JSON
$mp  = $obj.sections.PSObject.Properties | Where-Object { $_.Value.blocks.PSObject.Properties.Name -contains 'custom_liquid_KULMdX' } | Select-Object -First 1
$rt  = $mp.Value.blocks.custom_liquid_KULMdX.settings.custom_liquid
if ($rt -ne $new) { throw "DOGRULAMA HATASI: geri okunan blok yeni blokla ayni degil" }   # 2) tam esitlik
$oldObj = $raw | ConvertFrom-Json
$oldKeys = ($oldObj.sections.PSObject.Properties.Name | Sort-Object) -join ','
$newKeys = ($obj.sections.PSObject.Properties.Name | Sort-Object) -join ','
if ($oldKeys -ne $newKeys) { throw "DOGRULAMA HATASI: section listesi degisti" }           # 3) yapi bozulmadi
$oldBlocks = ($oldObj.sections.PSObject.Properties | ForEach-Object { $_.Value.blocks.PSObject.Properties.Name } | Sort-Object) -join ','
$newBlocks = ($obj.sections.PSObject.Properties | ForEach-Object { $_.Value.blocks.PSObject.Properties.Name } | Sort-Object) -join ','
if ($oldBlocks -ne $newBlocks) { throw "DOGRULAMA HATASI: blok listesi degisti" }
$expectedDelta = (Escape-JsonString $new).Length - $oldEsc.Length
if (($patched.Length - $raw.Length) -ne $expectedDelta) { throw "DOGRULAMA HATASI: beklenmeyen uzunluk farki" }

Write-Host ""
Write-Host "DOGRULAMA: JSON gecerli / blok tam olarak yazildi / section+blok listesi ayni"
Write-Host ("  sablon: {0} -> {1} kar" -f $raw.Length, $patched.Length)

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$bakPath = Join-Path $PSScriptRoot ("theme\templates__product.json.bak_precartfix_{0}" -f $stamp)
$prePath = Join-Path $PSScriptRoot ("theme\templates__product.json.cartfix_{0}" -f $stamp)
[IO.File]::WriteAllText($bakPath, $raw, $eu8)
[IO.File]::WriteAllText($prePath, $patched, $eu8)
Write-Host ("  yedek : {0}" -f $bakPath)
Write-Host ("  onizl.: {0}" -f $prePath)

if (-not $Apply) {
  Write-Host ""
  Write-Host "KURU CALISMA - canli temaya DOKUNULMADI. Uygulamak icin: -Apply"
  return
}

Put-Asset $patched
Start-Sleep -Seconds 2
$chk = Get-Asset
$chkSpan = Find-KulmdxSpan $chk
$chkVal = ('"' + $chk.Substring($chkSpan.Start, $chkSpan.Length) + '"' | ConvertFrom-Json)
Write-Host ""
Write-Host ("PUT SONRASI: JSON gecerli={0} | isMainForm={1} | var SUR={2} | blok==yeni={3}" -f `
  $(try { [bool]($chk | ConvertFrom-Json) } catch { $false }), ($chkVal -match 'isMainForm'), ($chkVal -match 'var SUR'), ($chkVal -eq $new))
Write-Host ("GERI ALMAK ICIN: pwsh -File patch_cart_selector.ps1 -Rollback `"{0}`"" -f $bakPath)
