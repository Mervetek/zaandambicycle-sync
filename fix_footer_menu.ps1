# Footer menusundeki olu (#) linkleri gercek politika + koleksiyon sayfalarina bagla.
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$shop="8t0pzm-g1.myshopify.com"; $api="2024-10"
$tok=(Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) -ContentType 'application/json').access_token
$hr=@{"X-Shopify-Access-Token"=$tok}
$hg=@{"X-Shopify-Access-Token"=$tok; "Content-Type"="application/json"}

# politika URL'leri
$pol=(Invoke-RestMethod -Uri "https://$shop/admin/api/$api/policies.json" -Headers $hr).policies
$u=@{}; foreach($p in $pol){ $u[$p.title]=$p.url }
$pol | ForEach-Object { Write-Host ("  {0} -> {1}" -f $_.title,$_.url) }
$privacy=($pol|?{$_.title -match 'Privacy'}).url
$refund =($pol|?{$_.title -match 'Refund|Return'}).url
$ship   =($pol|?{$_.title -match 'Shipping'}).url
$terms  =($pol|?{$_.title -match 'Terms'}).url

# footer menu items (tek seviye alt-baslikli)
$items=@(
  @{ title='Klantenservice'; type='HTTP'; url='mailto:info@zaandambicycle.nl'; items=@(
      @{ title='Verzending & bezorging'; type='HTTP'; url=$ship },
      @{ title='Retourneren'; type='HTTP'; url=$refund }
  )},
  @{ title='Juridisch'; type='HTTP'; url=$terms; items=@(
      @{ title='Algemene voorwaarden'; type='HTTP'; url=$terms },
      @{ title='Privacybeleid'; type='HTTP'; url=$privacy }
  )},
  @{ title='Fietsen'; type='HTTP'; url='/collections/all'; items=@(
      @{ title='E-Bikes'; type='HTTP'; url='/collections/e-bikes' },
      @{ title='Stads- en toerfietsen'; type='HTTP'; url='/collections/stads-en-toerfietsen' },
      @{ title='Kinderfietsen'; type='HTTP'; url='/collections/kinderfietsen' },
      @{ title='Vouwfietsen'; type='HTTP'; url='/collections/vouwfietsen' }
  )}
)
# NOT: /pages/contact henuz yok (write_content scope gerekli) -> simdilik Klantenservice basligi customer_support blogunda; menu ust link zararsiz.

$mutation='mutation menuUpdate($id: ID!, $title: String!, $handle: String!, $items: [MenuItemUpdateInput!]!) { menuUpdate(id:$id, title:$title, handle:$handle, items:$items){ menu{ id } userErrors{ field message } } }'
$vars=@{ id='gid://shopify/Menu/326551798147'; title='Menu Footer'; handle='footer'; items=$items }
$body=@{ query=$mutation; variables=$vars } | ConvertTo-Json -Depth 10
$r=Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $hg -Body ([Text.Encoding]::UTF8.GetBytes($body))
if($r.errors){ Write-Host "GRAPHQL ERR: $($r.errors.message -join '; ')" }
if($r.data.menuUpdate.userErrors){ Write-Host "USER ERR: $(( $r.data.menuUpdate.userErrors | ForEach-Object { $_.field, $_.message -join ':' }) -join ' | ')" }
if($r.data.menuUpdate.menu.id){ Write-Host "footer menu guncellendi: $($r.data.menuUpdate.menu.id)" }
