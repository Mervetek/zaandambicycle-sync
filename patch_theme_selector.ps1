# DIKKAT: bu dosya UTF-8 BOM'LU KALMALI - euro isareti iceriyor; BOM'suz kaydedilirse PS 5.1 ANSI okur ve tema mojibake olur
# Tema yamasi: bc-selector (urun) + acc-upsell (sepet) bloklarini yeniler.
# - SUR fark-urunu mekanizmasi KALDIRILDI (urunu silinmisti, tahsilat kirikti)
# - Aku artik GERCEK urun varyantiyla sepete eklenir (b.variant_id)
# - available=false akuler gri/secilemez cizilir: "Tijdelijk uitverkocht · verwacht wk X"
# - Sepete ekleme basarisiz olursa SESSIZ dusme yok: uyari gosterilir
if (-not $env:SHOPIFY_CLIENT_SECRET) { . (Join-Path $PSScriptRoot "_load_env.ps1") }
$ErrorActionPreference = 'Stop'
$themeDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\theme"
$shop = "8t0pzm-g1.myshopify.com"; $api = "2024-10"
$tid = "gid://shopify/OnlineStoreTheme/196327965059"

# ================= YENI URUN SAYFASI LIQUID =================
$productLiquid = @'
{%- comment -%}
  ACCU + LADER secici (BIRLESIK blok, v2 2026-07-06).
  - Accu = GERCEK aku urunu varyanti (specs.battery_options[].variant_id) - SUR mekanizmasi kaldirildi
  - available=false akuler gri/secilemez: "Tijdelijk uitverkocht" + verwacht week (eta)
  - included=true (sabit aku) "Inbegrepen" olarak cizilir, sepete ayri satir eklenmez
  - Lader = gercek sarj urunu varyanti (specs.charger_options)
{%- endcomment -%}
{%- assign batts = product.metafields.specs.battery_options.value -%}
{%- assign chargers = product.metafields.specs.charger_options.value -%}
{%- if batts.size > 0 or chargers.size > 0 -%}
  <div class="bc-selector" data-base="{{ product.price }}" style="margin:16px 0;">

    {%- if batts.size > 0 -%}
      <label style="display:block;font-weight:600;margin-bottom:8px;">Accu</label>
      <div style="display:flex;flex-direction:column;gap:8px;">
        {%- assign firstsel = false -%}
        {%- for b in batts -%}
          {%- if b.included -%}
            <label style="display:flex;align-items:center;gap:10px;border:1px solid #ccc;border-radius:6px;padding:10px 14px;cursor:pointer;">
              <input type="radio" name="battery-opt" value="" data-price="0" data-label="{{ b.capacity_wh }}Wh (inbegrepen)" {% if firstsel == false %}checked{% assign firstsel = true %}{% endif %}>
              <span style="font-weight:600;">{{ b.capacity_wh }}Wh</span>
              <span style="margin-left:auto;color:#0a7d28;font-weight:600;">Inbegrepen</span>
            </label>
          {%- elsif b.available == false -%}
            <label style="display:flex;align-items:center;gap:10px;border:1px dashed #d1d5db;border-radius:6px;padding:10px 14px;cursor:not-allowed;opacity:.6;background:#f9fafb;">
              <input type="radio" name="battery-opt" disabled>
              <span style="font-weight:600;color:#6b7280;">{{ b.capacity_wh }}Wh</span>
              <span style="margin-left:auto;color:#b45309;font-weight:600;font-size:.92em;">Tijdelijk uitverkocht{% if b.eta != blank %} &middot; verwacht wk {{ b.eta | split: '/' | first }}{% endif %}</span>
            </label>
          {%- else -%}
            <label style="display:flex;align-items:center;gap:10px;border:1px solid #ccc;border-radius:6px;padding:10px 14px;cursor:pointer;">
              <input type="radio" name="battery-opt" value="{{ b.variant_id }}" data-price="{{ b.additional_cost }}" data-label="{{ b.capacity_wh }}Wh (+ {{ b.additional_cost | times: 100 | money }})" {% if firstsel == false %}checked{% assign firstsel = true %}{% endif %}>
              <span style="font-weight:600;">{{ b.capacity_wh }}Wh</span>
              <span style="margin-left:auto;color:#0a7d28;font-weight:600;">+ {{ b.additional_cost | times: 100 | money }}</span>
            </label>
          {%- endif -%}
        {%- endfor -%}
      </div>
    {%- endif -%}

    {%- comment -%} "Geen extra lader" secenegi patron talimatiyla KALDIRILDI (2026-07-06):
        lader secimi zorunlu, ilk (en ucuz) lader varsayilan secili - eski site davranisiyla ayni {%- endcomment -%}
    {%- if chargers.size > 0 -%}
      <label style="display:block;font-weight:600;margin:16px 0 8px;">Lader</label>
      <div style="display:flex;flex-direction:column;gap:8px;">
        {%- for c in chargers -%}
          <label style="display:flex;align-items:center;gap:10px;border:1px solid #ccc;border-radius:6px;padding:10px 14px;cursor:pointer;">
            <input type="radio" name="charger-opt" value="{{ c.variant_id }}" data-price="{{ c.price }}" {% if forloop.first %}checked{% endif %}>
            <span style="font-weight:600;">{{ c.name }}</span>
            <span style="margin-left:auto;color:#0a7d28;font-weight:600;">+ {{ c.price | times: 100 | money }}</span>
          </label>
        {%- endfor -%}
      </div>
    {%- endif -%}

    <div style="margin-top:12px;font-size:1.1em;font-weight:700;">
      Totaal: <span class="bc-total">{{ product.price | money }}</span>
    </div>
  </div>
  <script>
  (function(){
    var box = document.querySelector('.bc-selector');
    if(!box) return;
    var base = parseInt(box.getAttribute('data-base'),10) || 0;
    var totalEl = box.querySelector('.bc-total');
    function fmt(c){ return '€ ' + (c/100).toLocaleString('nl-NL',{minimumFractionDigits:2,maximumFractionDigits:2}); }
    function bsel(){ return box.querySelector('input[name="battery-opt"]:checked'); }
    function csel(){ return box.querySelector('input[name="charger-opt"]:checked'); }
    function calc(){
      var bc = bsel() ? (parseFloat(bsel().getAttribute('data-price'))||0) : 0;
      var cc = csel() ? (parseFloat(csel().getAttribute('data-price'))||0) : 0;
      totalEl.textContent = fmt(base + Math.round(bc*100) + Math.round(cc*100));
    }
    box.querySelectorAll('input[name="battery-opt"],input[name="charger-opt"]').forEach(function(r){ r.addEventListener('change', calc); });
    calc();

    var mainVariants = {{ product.variants | map: 'id' | json }};
    function isMainForm(form){
      if(!form) return false;
      var idi = form.querySelector('[name="id"]');
      return !!(idi && mainVariants.indexOf(parseInt(idi.value,10)) >= 0);
    }
    var busy = false;
    function addToCart(form){
      if(busy) return; busy = true;
      var idInput = form.querySelector('[name="id"]');
      var qEl = form.querySelector('[name="quantity"]') || document.querySelector('input[name="quantity"]');
      var qty = parseInt((qEl||{}).value,10) || 1;
      var items = [];
      var br = bsel();
      items.push({ id: parseInt(idInput.value,10), quantity: qty, properties: br ? {"Accu": br.getAttribute('data-label')} : {} });
      if(br && br.value){
        items.push({ id: parseInt(br.value,10), quantity: qty, properties: {"Accu voor": {{ product.title | json }} } });
      }
      var cr = csel();
      if(cr && cr.value){
        items.push({ id: parseInt(cr.value,10), quantity: qty, properties: {"Lader voor": {{ product.title | json }} } });
      }
      fetch('/cart/add.js', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({items:items}) })
        .then(function(res){ if(!res.ok) throw 0; window.location = '/cart'; })
        .catch(function(){ busy=false; alert('Kon niet toevoegen aan winkelwagen. Probeer het opnieuw of neem contact op.'); });
    }
    // Xtra temasinin butonunda name="add" YOK (class="override" vb. type=submit) - hem submit hem click
    // yakalama sart; sadece ANA urunun formunda devreye gir (oneri urunlerinin quick-buy'ina karisma)
    document.addEventListener('submit', function(ev){
      var form = ev.target;
      if(!form || !form.getAttribute) return;
      if(String(form.getAttribute('action')||'').indexOf('/cart/add') < 0) return;
      if(!isMainForm(form)) return;
      ev.preventDefault(); ev.stopImmediatePropagation();
      addToCart(form);
    }, true);
    document.addEventListener('click', function(ev){
      var btn = ev.target.closest('button[type="submit"], [name="add"]');
      if(!btn) return;
      var form = btn.closest('form');
      if(!form){ var fid = btn.getAttribute('form'); if(fid) form = document.getElementById(fid); }
      if(!form || String(form.getAttribute('action')||'').indexOf('/cart/add') < 0) return;
      if(!isMainForm(form)) return;
      ev.preventDefault(); ev.stopImmediatePropagation();
      addToCart(form);
    }, true);
  })();
  </script>
{%- endif -%}
'@

# ================= YENI SEPET UPSELL LIQUID =================
$cartLiquid = @'
{%- comment -%}
  Sepet aksesuar hatirlatmasi (v2 2026-07-06) - sepetteki her bisiklet icin aku/lader "ekle" butonlari.
  Aku = GERCEK urun varyanti (variant_id); SUR kaldirildi. Stokta olmayan/dahil akuler gosterilmez.
{%- endcomment -%}
{%- assign show = false -%}
{%- for item in cart.items -%}
  {%- if item.product.metafields.specs.charger_options.value or item.product.metafields.specs.battery_options.value -%}
    {%- assign show = true -%}
  {%- endif -%}
{%- endfor -%}
{%- if show -%}
  <div class="acc-upsell" style="margin:16px 0;padding:16px 18px;border:1px solid #e5e7eb;border-radius:12px;background:#fff;">
    <div style="font-weight:700;font-size:15px;color:#111;">Vergeet uw accu of lader niet</div>
    <p style="margin:2px 0 14px;font-size:13px;color:#6b7280;">Voeg eenvoudig toe aan uw bestelling.</p>
    {%- for item in cart.items -%}
      {%- assign chargers = item.product.metafields.specs.charger_options.value -%}
      {%- assign batts = item.product.metafields.specs.battery_options.value -%}
      {%- if chargers or batts -%}
        <div class="acc-bike" style="margin-bottom:12px;">
          <div style="font-size:12px;color:#9ca3af;margin-bottom:7px;">{{ item.product.title }}</div>
          <div style="display:flex;flex-wrap:wrap;gap:8px;">
            {%- if batts -%}
              {%- for b in batts -%}
                {%- if b.additional_cost and b.additional_cost > 0 and b.available != false and b.variant_id != blank -%}
                  <span class="acc-btn" role="button" tabindex="0" data-variant="{{ b.variant_id }}" data-type="batt" data-cap="{{ b.capacity_wh }}Wh" data-bike="{{ item.product.title | escape }}">+ Accu {{ b.capacity_wh }}Wh &middot; &euro;{{ b.additional_cost }}</span>
                {%- endif -%}
              {%- endfor -%}
            {%- endif -%}
            {%- if chargers -%}
              {%- for c in chargers -%}
                <span class="acc-btn" role="button" tabindex="0" data-variant="{{ c.variant_id }}" data-type="charger" data-bike="{{ item.product.title | escape }}">+ {{ c.name }} &middot; &euro;{{ c.price }}</span>
              {%- endfor -%}
            {%- endif -%}
          </div>
        </div>
      {%- endif -%}
    {%- endfor -%}
  </div>
  <style>
    .acc-upsell .acc-btn{display:inline-block;cursor:pointer;border:1px solid #d1d5db;background:#fff;color:#111827;border-radius:9px;padding:9px 14px;font-size:13px;font-weight:600;line-height:1.2;transition:.15s;}
    .acc-upsell .acc-btn:hover{border-color:#111827;background:#f9fafb;}
  </style>
  <script>
  (function(){
    var box = document.querySelector('.acc-upsell'); if(!box) return;
    var inCart = [{% for item in cart.items %}{{ item.variant_id }}{% unless forloop.last %},{% endunless %}{% endfor %}];
    box.querySelectorAll('.acc-btn').forEach(function(btn){
      var vid = btn.getAttribute('data-variant');
      var isCharger = btn.getAttribute('data-type') === 'charger';
      if(vid && inCart.indexOf(parseInt(vid,10)) >= 0) { btn.style.display = 'none'; }
      function add(){
        if(!vid || btn.dataset.busy) return; btn.dataset.busy = '1'; btn.style.opacity = .5;
        var props = isCharger ? { 'Lader voor': btn.getAttribute('data-bike') }
                              : { 'Accu voor': btn.getAttribute('data-bike') };
        fetch('/cart/add.js', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ items:[{ id: parseInt(vid,10), quantity:1, properties: props }] }) })
          .then(function(r){ if(!r.ok) throw 0; window.location.reload(); })
          .catch(function(){ btn.dataset.busy=''; btn.style.opacity=1; alert('Kon niet toevoegen'); });
      }
      btn.addEventListener('click', add);
      btn.addEventListener('keydown', function(e){ if(e.key==='Enter'||e.key===' '){ e.preventDefault(); add(); } });
    });
    box.querySelectorAll('.acc-bike').forEach(function(g){
      if(![].some.call(g.querySelectorAll('.acc-btn'), function(b){ return b.style.display !== 'none'; })) g.style.display = 'none';
    });
    if(![].some.call(box.querySelectorAll('.acc-btn'), function(b){ return b.style.display !== 'none'; })) box.style.display = 'none';
  })();
  </script>
{%- endif -%}
'@

# ================= JSON'lari guncelle =================
function StripComment($raw) {
    if ($raw -match '^(?s)\s*/\*.*?\*/\s*(.*)$') { return $Matches[1] }
    return $raw
}
$pRaw = StripComment ([IO.File]::ReadAllText("$themeDir\templates__product.json"))
$pJson = $pRaw | ConvertFrom-Json
$pJson.sections.'main-product'.blocks.custom_liquid_KULMdX.settings.custom_liquid = $productLiquid
# "Buy it now" dinamik odeme butonu KAPALI: sepeti atlayip aku/lader'siz satisa yol aciyor (2026-07-06)
$pJson.sections.'main-product'.blocks.buy_button.settings.show_dynamic_buybutton = $false
$pOut = $pJson | ConvertTo-Json -Depth 50

$cRaw = StripComment ([IO.File]::ReadAllText("$themeDir\templates__cart.json"))
$cJson = $cRaw | ConvertFrom-Json
$cJson.sections.section_custom_liquid_mwcFTC.settings.custom_liquid = $cartLiquid
$cOut = $cJson | ConvertTo-Json -Depth 50

# yedekleri sakla
Copy-Item "$themeDir\templates__product.json" "$themeDir\templates__product.json.bak" -Force
Copy-Item "$themeDir\templates__cart.json" "$themeDir\templates__cart.json.bak" -Force
[IO.File]::WriteAllText("$themeDir\templates__product.json.new", $pOut, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$themeDir\templates__cart.json.new", $cOut, [Text.UTF8Encoding]::new($false))

# ================= Shopify'a yaz =================
$sb = @{ grant_type = "client_credentials"; client_id = $env:SHOPIFY_CLIENT_ID; client_secret = $env:SHOPIFY_CLIENT_SECRET } | ConvertTo-Json
$token = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body $sb -ContentType 'application/json' -TimeoutSec 30).access_token
$h = @{ "X-Shopify-Access-Token" = $token }
$mutation = 'mutation UpsertFiles($themeId: ID!, $files: [OnlineStoreThemeFilesUpsertFileInput!]!) { themeFilesUpsert(themeId: $themeId, files: $files) { upsertedThemeFiles { filename } userErrors { field message } } }'
$body = @{ query = $mutation; variables = @{ themeId = $tid; files = @(
    @{ filename = 'templates/product.json'; body = @{ type = 'TEXT'; value = $pOut } }
    @{ filename = 'templates/cart.json'; body = @{ type = 'TEXT'; value = $cOut } }
) } } | ConvertTo-Json -Depth 12
# KRITIK: govde UTF-8 BAYT olarak gonderilmeli - PS 5.1 string govdeyi ISO-8859-1 kodlar, euro '?'ye donusur
$r = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
if ($r.errors) { Write-Host "GRAPHQL HATA: $($r.errors[0].message)"; exit 1 }
$ue = @($r.data.themeFilesUpsert.userErrors)
if ($ue.Count) { Write-Host "USER ERROR: $($ue | ForEach-Object { "$($_.field): $($_.message)" })"; exit 1 }
Write-Host "YAZILDI: $(@($r.data.themeFilesUpsert.upsertedThemeFiles).Count) dosya -> $((@($r.data.themeFilesUpsert.upsertedThemeFiles) | ForEach-Object { $_.filename }) -join ', ')"
