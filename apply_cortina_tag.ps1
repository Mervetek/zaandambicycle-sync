# 89 Cortina e-bike'a 'accu-op-aanvraag' etiketi ekle (tagsAdd, idempotent).
# Tema bu etikete gore seciciyi gizleyip iletisim formu gosterir. Metafield'lar SILINMEZ (geri alinabilir).
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hg=@{"X-Shopify-Access-Token"=$tok; "Content-Type"="application/json"}
$targets=Import-Csv (Join-Path $PSScriptRoot "data\cortina_form_hedef.csv")
$ok=0; $err=0
foreach($t in $targets){
  $m='mutation($id:ID!,$tags:[String!]!){ tagsAdd(id:$id, tags:$tags){ userErrors{message} } }'
  $body=@{ query=$m; variables=@{ id=$t.id; tags=@('accu-op-aanvraag') } } | ConvertTo-Json -Depth 6
  $r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hg -Body ([Text.Encoding]::UTF8.GetBytes($body))
  if($r.errors -or $r.data.tagsAdd.userErrors){ $err++; Write-Host ("HATA {0}: {1}" -f $t.title, (($r.errors.message + $r.data.tagsAdd.userErrors.message) -join '; ')) }
  else { $ok++ }
  Start-Sleep -Milliseconds 120
}
Write-Host ("etiketlendi: {0} | hata: {1}" -f $ok,$err)
