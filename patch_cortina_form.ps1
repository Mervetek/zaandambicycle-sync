# KULMdX blogunu tag-gecidiyle sar: accu-op-aanvraag etiketli urunde FORM, digerinde eski secici.
# Ham JSON uzerinde 2 ankraj ile string-insert; PUT UTF-8 BYTE. Once yedek.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hr=@{"X-Shopify-Access-Token"=$tok}
$themes=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $hr).themes
$main=($themes|?{$_.role -eq 'main'})
$key='templates/product.json'
$pj=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $hr).asset.value
$eu8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "theme\templates__product.json.bak_precortinaform"),$pj,$eu8)

# zaten yamalı mı?
if($pj -match 'accu-op-aanvraag'){ Write-Host "ZATEN YAMALI - cikiliyor"; return }

# FORM (single-quoted here-string; liquid tag'leri literal)
$form=@'
<div id="accu-aanvraag" style="margin:16px 0;padding:16px;border:1px solid #e5e7eb;border-radius:8px;background:#f9fafb;">
  <h3 style="margin:0 0 6px;font-size:1.05em;">Accu &amp; lader op aanvraag</h3>
  <p style="margin:0 0 12px;color:#374151;font-size:.95em;">Voor dit model stellen wij de accu en lader graag persoonlijk met u samen. Laat uw gegevens achter, dan neemt onze winkel zo snel mogelijk contact met u op voor advies op maat.</p>
  <div class="aanvraag-bedankt" style="display:none;margin-bottom:12px;padding:10px 14px;border-radius:6px;background:#dcfce7;color:#166534;font-weight:600;">Bedankt! Wij nemen zo snel mogelijk contact met u op.</div>
  <form action="https://formsubmit.co/mervetek.bilgmuh@gmail.com" method="POST" class="aanvraag-form" style="display:flex;flex-direction:column;gap:10px;">
    <input type="hidden" name="_subject" value="Accu/lader aanvraag - {{ product.title | escape }}">
    <input type="hidden" name="_template" value="table">
    <input type="hidden" name="_captcha" value="false">
    <input type="hidden" name="Fiets" value="{{ product.title | escape }}">
    <input type="hidden" name="Artikelnummer" value="{{ product.selected_or_first_available_variant.sku }}">
    <input type="hidden" name="_next" value="{{ shop.secure_url }}{{ product.url }}?aanvraag=verzonden">
    <input type="text" name="Naam" placeholder="Naam" required style="padding:10px;border:1px solid #ccc;border-radius:6px;">
    <input type="email" name="email" placeholder="E-mailadres" required style="padding:10px;border:1px solid #ccc;border-radius:6px;">
    <input type="tel" name="Telefoon" placeholder="Telefoonnummer" style="padding:10px;border:1px solid #ccc;border-radius:6px;">
    <textarea name="Bericht" rows="3" placeholder="Uw vraag of gewenste accucapaciteit" style="padding:10px;border:1px solid #ccc;border-radius:6px;"></textarea>
    <button type="submit" style="padding:12px;border:0;border-radius:6px;background:#111827;color:#fff;font-weight:600;cursor:pointer;">Verstuur aanvraag</button>
  </form>
  <script>(function(){if(location.search.indexOf('aanvraag=verzonden')>-1){var b=document.querySelector('#accu-aanvraag .aanvraag-bedankt');var f=document.querySelector('#accu-aanvraag .aanvraag-form');if(b)b.style.display='block';if(f)f.style.display='none';}})();</script>
</div>
'@
$open = "{%- if product.tags contains 'accu-op-aanvraag' -%}" + $form + "{%- else -%}"
# JSON-escape (tirnaklari sil)
$je = $open | ConvertTo-Json
$openEsc = $je.Substring(1, $je.Length-2)

# ANKRAJ 1: secici basi (unique) - oncesine wrapper-open koy
$anchor1='{%- assign batts = product.metafields.specs.battery_options.value -%}'
$c1=([regex]::Matches($pj,[regex]::Escape($anchor1))).Count
# ANKRAJ 2: terminal endif + kapanis tirnak (opsiyonel \n)
$c2=([regex]::Matches($pj,'\{%- endif -%\}(\\n)?"')).Count
Write-Host ("ankraj1 (assign batts): {0} | ankraj2 (terminal endif): {1}" -f $c1,$c2)
if($c1 -ne 1){ Write-Host "ANKRAJ1 benzersiz degil - DUR"; return }

if($c2 -ne 1){ Write-Host "ANKRAJ2 benzersiz degil - DUR"; return }
$pj2 = $pj.Replace($anchor1, $openEsc + $anchor1)
# kapanis: terminal endif+kapanis-tirnak (benzersiz) -> araya wrapper-if kapanisi
$pj3 = [regex]::Replace($pj2, '\{%- endif -%\}((?:\\n)?)"', '{%- endif -%}{%- endif -%}$1"')
if($pj3 -eq $pj2){ Write-Host "KAPANIS eklenemedi - DUR"; return }

# gecerli JSON mi?
try { $null = $pj3 | ConvertFrom-Json; Write-Host "JSON gecerli" } catch { Write-Host "JSON BOZUK - DUR: $_"; return }

$body=@{ asset=@{ key=$key; value=$pj3 } } | ConvertTo-Json -Depth 6
$null=Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json" -Headers $hr -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
Start-Sleep -Seconds 2
$chk=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=$key" -Headers $hr).asset.value
Write-Host ("PUT sonrasi: accu-op-aanvraag var={0} | formsubmit var={1} | JSON gecerli={2}" -f ($chk -match 'accu-op-aanvraag'),($chk -match 'formsubmit.co'),$(try{[bool]($chk|ConvertFrom-Json)}catch{$false}))
