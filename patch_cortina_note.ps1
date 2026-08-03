# Cortina secicisinin altina "aku/lader bilgisi degisebilir, satici ile iletisim" NOTU ekler.
# Sadece product.vendor == 'Cortina' iken gorunur. Idempotent (accu-let-op varsa atlar).
# Ham JSON string-insert + UTF-8 byte PUT (euro literal korunur). Yedek: theme\templates__product.json.bak_precortinanote
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$EUR=[char]0x20AC
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hr=@{"X-Shopify-Access-Token"=$tok}
$hg=@{"X-Shopify-Access-Token"=$tok; "Content-Type"="application/json; charset=utf-8"}
$main=((Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes.json" -Headers $hr).themes | Where-Object { $_.role -eq 'main' })
$raw=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json?asset[key]=templates/product.json" -Headers $hr).asset.value

if ($raw -match 'accu-let-op') { Write-Host "NOT zaten var, atlandi (idempotent)."; return }

$eu8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "theme\templates__product.json.bak_precortinanote"),$raw,$eu8)

$anchor = 'class=\"bc-total\">{{ product.price | money }}<\/span>\n    <\/div>'
$occ = ([regex]::Matches($raw,[regex]::Escape($anchor))).Count
if ($occ -ne 1) { Write-Host ("HATA: anchor {0} kez bulundu (1 olmali) - iptal." -f $occ); return }

$note = '{%- if product.vendor == ''Cortina'' -%}<div class=\"accu-let-op\" style=\"margin:14px 0 0;padding:12px 14px;border:1px solid #f0c26b;border-radius:8px;background:#fffaf0;color:#7a4f10;font-size:.9em;line-height:1.5;\"><strong>Let op:<\/strong> de accu- en laderinformatie kan afwijken. Neem contact op met de winkel voordat u bestelt, om de juiste accu en lader te bevestigen.<br>E-mail: <a href=\"mailto:info@zaandambicycle.nl\" style=\"color:#7a4f10;font-weight:600;\">info@zaandambicycle.nl<\/a> &middot; Telefoon: <a href=\"tel:+31756175839\" style=\"color:#7a4f10;font-weight:600;\">075 617 5839<\/a><\/div>{%- endif -%}'
$replacement = $anchor + '\n  ' + $note
$new = $raw.Replace($anchor, $replacement)

# Dogrulama
if ($new -eq $raw) { Write-Host "HATA: degisiklik olmadi."; return }
if (([regex]::Matches($new,'accu-let-op')).Count -ne 1) { Write-Host "HATA: not tam 1 kez eklenmedi."; return }
try { $null = $new | ConvertFrom-Json } catch { Write-Host "HATA: sonuc gecerli JSON degil - iptal. $($_.Exception.Message)"; return }
if (-not $new.Contains($EUR)) { Write-Host "HATA: euro kayboldu - iptal."; return }
$euroSayi = ([regex]::Matches($new,[regex]::Escape([string]$EUR))).Count
Write-Host ("dogrulama OK | eski {0} -> yeni {1} kar | euro sayisi {2}" -f $raw.Length,$new.Length,$euroSayi)

$body = @{ asset = @{ key='templates/product.json'; value=$new } } | ConvertTo-Json -Depth 6 -Compress
$r = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/themes/$($main.id)/assets.json" -Headers $hg -Body ([Text.Encoding]::UTF8.GetBytes($body))
Write-Host ("PUT tamam: {0} guncellendi ({1} kar)" -f $r.asset.key, $r.asset.value.Length)
