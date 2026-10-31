# Zaandam Bicycle - Sistem Rehberi

Bu proje, **Zaandam Bicycle** (zaandambicycle.nl) mağazasının Shopify altyapısını yönetir. Tedarikçi portallarından ürün verisi çeker, stok/fiyat senkronizasyonu yapar ve tema özelleştirmelerini barındırır.

---

## 1. Repo ve Ortam

### Repo
```
git clone https://github.com/Mervetek/zaandambicycle-sync.git
cd zaandambicycle-sync
```

### Gereksinimler
- **PowerShell 7+ (pwsh)** — tüm scriptler `pwsh -File` ile çalışır
- **Git** — sürüm kontrolü

### sync.env dosyası
Proje kökünde `sync.env` dosyası olmalı. `.gitignore`'dadır, repo'da yoktur. Mağaza sahibinden alınmalıdır.

```
KRUITBOSCH_USERNAME=<kruitbosch bayi numarası>
KRUITBOSCH_PASSWORD=<kruitbosch şifre>
KRUITBOSCH_CUSTOMER=<kruitbosch müşteri numarası>
ACCELL_USERNAME=<accell email>
ACCELL_PASSWORD=<accell şifre>
SHOPIFY_CLIENT_ID=<shopify app client id>
SHOPIFY_CLIENT_SECRET=<shopify app client secret>
SHOPIFY_SHOP=8t0pzm-g1.myshopify.com
SHOPIFY_LOCATION=118973399427
QWIC_USERNAME=<qwic dealer email>
QWIC_PASSWORD=<qwic dealer şifre>
```

`_load_env.ps1` bu dosyayı okuyup `$env:` değişkenlerine yükler. Tüm scriptler bunu otomatik çağırır.

---

## 2. Shopify Mağaza Bilgileri

| Bilgi | Değer |
|-------|-------|
| Mağaza domain | `8t0pzm-g1.myshopify.com` |
| Canlı site | `zaandambicycle.nl` |
| Shopify Admin | `https://8t0pzm-g1.myshopify.com/admin` |
| API sürümü | `2024-10` |
| Lokasyon ID | `118973399427` |
| Online Store Publication GID | `gid://shopify/Publication/338868208003` |
| POS Publication GID | `gid://shopify/Publication/338868240771` |
| Ana menü GID | `gid://shopify/Menu/326551765379` |
| Aktif tema ID | `196327965059` |

### Shopify API erişimi
Mağazada **client_credentials** OAuth kullanılıyor:
```powershell
$tok = (Invoke-RestMethod -Method Post -Uri "https://8t0pzm-g1.myshopify.com/admin/oauth/access_token" `
  -Body (@{grant_type='client_credentials';client_id=$env:SHOPIFY_CLIENT_ID;client_secret=$env:SHOPIFY_CLIENT_SECRET}|ConvertTo-Json) `
  -ContentType 'application/json').access_token
$h = @{ "X-Shopify-Access-Token" = $tok }
```
Bu pattern tüm scriptlerde tekrarlanır. Token her çalıştırmada yeniden alınır, cache'lenmez.

---

## 3. Markalar, Tedarikçiler ve Koleksiyonlar

### Koleksiyon ID'leri (Smart Collections, vendor-based rule)

| Marka | Koleksiyon ID | Tedarikçi |
|-------|---------------|-----------|
| Batavus | _(mevcut, admin'den bakılabilir)_ | Kruitbosch / Accell |
| Sparta | _(mevcut)_ | Kruitbosch / Accell |
| Cortina | _(mevcut)_ | Kruitbosch / Accell |
| Loekie | _(mevcut)_ | Kruitbosch / Accell |
| QWIC | `714259235203` | QWIC dealer portal |
| Conway | `714260578691` | Hartje |
| Excelsior | `714260611459` | Hartje |
| Noxon | `714260644227` | Hartje |
| Victoria | `714260676995` | Hartje |

Tüm koleksiyonlar `vendor equals <marka>` kuralıyla çalışır. Ürün vendor'ı doğru girildiğinde otomatik koleksiyona düşer.

### Tedarikçi Portalleri

| Tedarikçi | Portal URL | Giriş | Erişim tipi |
|-----------|-----------|-------|-------------|
| Kruitbosch | `webservice.kruitbosch.nl` | Basic Auth (sync.env) | REST API — otomatik |
| Accell/Accentry | `api-gateway.accentry.com` | Bearer token (sync.env) | REST API — otomatik |
| QWIC | `dealer.qwic.nl` | Email/şifre (sync.env) | Tarayıcı — manuel scrape |
| Hartje | `meinhartje.com` | `sso.hartje.de` SSO girişi | Tarayıcı — manuel scrape |

**Kruitbosch ve Accell** otomatik senkronize edilir (`daily_sync.ps1` tarafından).
**QWIC ve Hartje** portalleri API sunmaz, tarayıcıda JavaScript ile scrape edilir.

### Navigasyon Menüsü
Ana menüde (Merken altında) 18 alt marka linki var. Yeni marka eklendiğinde GraphQL `menuUpdate` mutation'ı ile eklenir:
```
gid://shopify/Menu/326551765379
```

---

## 4. Script Kataloğu

### Günlük Senkron (otomatik)
| Script | Açıklama |
|--------|----------|
| `daily_sync.ps1` | **ANA SENKRON**. Kruitbosch + Accell'den stok/fiyat çeker, Shopify'a yazar. Görev Zamanlayıcı ile günlük çalışır. Güvenlik frenleri var: veri az veya hata çoksa durur. |
| `activate_priced_drafts.ps1` | Shopify Flow tarafından draft yapılan görselli+fiyatlı ürünleri geri aktif eder. `daily_sync.ps1` sonunda çağrılır. |
| `rebuild_battery_options.ps1` | Flex bisikletlerin (Batavus/Sparta) batarya seçeneklerini taze tedarikçi stok/fiyatıyla günceller. |
| `build_cortina_options.ps1` | Cortina akü/şarj seçeneklerini günceller. |
| `discover_flex_links.ps1` | Yeni Flex bisikletlerin akü/şarj bağlantılarını keşfeder. |
| `enforce_accell_no_charger.ps1` | Batavus/Sparta/Loekie'de şarj fiyata dahil olduğu için yanlış eklenen charger_options'ı temizler. |

### Import Scriptleri (tek seferlik / ihtiyaç halinde)
| Script | Açıklama | Kullanım |
|--------|----------|----------|
| `import_hartje.ps1` | Conway/Victoria/Excelsior/Noxon ürünlerini ekler | `pwsh -File import_hartje.ps1 -Brand All -Apply` |
| `import_qwic.ps1` | QWIC ürünlerini ekler | `pwsh -File import_qwic.ps1 -Apply` |
| `import_new_accell.ps1` | Yeni Accell ürünlerini ekler | `pwsh -File import_new_accell.ps1 -Apply` |

### Patch/Update Scriptleri (tek seferlik / ihtiyaç halinde)
| Script | Açıklama | Kullanım |
|--------|----------|----------|
| `patch_qwic_battery.ps1` | QWIC'e `battery_options` metafield yazar, accu upgrade ürünü oluşturur | `pwsh -File patch_qwic_battery.ps1 -Apply` |
| `patch_qwic_sku.ps1` | QWIC SKU'ları dealer portal ile eşleştirir | `pwsh -File patch_qwic_sku.ps1 -Apply` |
| `update_qwic.ps1` | QWIC stok durumuna göre aktif/draft yapar | `pwsh -File update_qwic.ps1 -Apply` |
| `patch_cart_selector.ps1` | Sepet seçici düzeltmesi | |
| `patch_cortina_form.ps1` | Cortina sipariş formu yaması | |
| `patch_cortina_note.ps1` | Cortina sipariş notu yaması | |

### Scrape Scriptleri
| Script | Açıklama |
|--------|----------|
| `scrape_qwic.ps1` | QWIC dealer portalından ürün listesi çeker |

**Not**: Tüm import/patch scriptler `-Apply` switch'i olmadan **kuru çalışma** yapar — Shopify'a yazmaz, ne yapacağını ekrana basar.

---

## 5. Tema Dosyaları (`theme/`)

Shopify temasındaki özelleştirilmiş dosyalar. Dosya adlarında `__` gerçek dizin ayırıcısını (`/`) temsil eder:
- `templates__product.json` → `templates/product.json` — Varsayılan ürün şablonu (Batavus/Sparta/Cortina akü/şarj seçicisi ile)
- `templates__product.qwic.json` → `templates/product.qwic.json` — QWIC şablonu (KULMdX batarya seçici v2)
- `templates__product.batavus.json` → `templates/product.batavus.json` — Batavus şablonu
- `templates__product.sparta.json` → `templates/product.sparta.json` — Sparta şablonu
- `sections__main-product.liquid` — Ana ürün bölümü
- `snippets__main-product-info.liquid` — Ürün bilgi snippet'i

### KULMdX Bloğu (Akü/Şarj Seçici)
Sepete ekleme sırasında akü ve şarj seçimi yapan özel Liquid+JS bloğu. `custom_liquid` section bloğu olarak **3 şablona ayrı ayrı** kopyalanmıştır:
1. `templates__product.json` (varsayılan — Cortina/Batavus/Sparta)
2. `templates__product.batavus.json`
3. `templates__product.sparta.json`

**DİKKAT**: Bu bloğu değiştirirken **her üç şablonu da** güncellemelisiniz! Biri unutulursa o marka için seçici sessizce bozulur.

QWIC şablonunda (`templates__product.qwic.json`) farklı bir KULMdX v2 bloğu var — batarya upgrade mekanizması ayrıdır.

---

## 6. Veri Dosyaları (`data/`)

| Dosya | Format | Açıklama |
|-------|--------|----------|
| `hartje_import_data.csv` | pipe-delimited (`vendor\|model\|category\|price\|artNr\|suffix`) | Hartje 4 marka ürün verileri (346 satır) |
| `hartje_all_products.json` | JSON | Hartje portalından scrape edilen tüm ürünler (fiyatsızlar dahil) |
| `qwic_dealer_products.csv` | CSV | QWIC dealer portal ürün+stok: model, sku, color, size, frame, stock, battery, dealer_price |
| `qwic_products.json` | JSON | QWIC ürün verileri |
| `qwic_sku_match_rapor.csv` | CSV | QWIC SKU eşleştirme raporu: 52 ürün, Shopify ↔ dealer portal |
| `accentry_stok.csv` | CSV | Accell stok kapsam listesi (sku bazlı) |
| `kruitbosch_products_attrs.json` | JSON | Kruitbosch ürün özellikleri |
| `import_new_done.txt` | Text | Son import'ta eklenen ürün ID'leri |

---

## 7. KRİTİK: Shopify Flow Sorunu ve Çözümü

### Sorun
Mağazada bir **Shopify Flow** otomasyonu var:
> **Görseli olmayan ürünler otomatik olarak `draft` (taslak) yapılıyor.**

Bu, yeni eklenen Hartje ürünlerinin (Conway, Victoria, Excelsior, Noxon) sitede **görünmemesine** neden oluyor. Ürünler API ile `active` yapılsa bile Flow **birkaç saniye içinde** tekrar `draft`'a çeviriyor.

**Kanıt**: `daily_sync.ps1` satır 269-275:
> *"stok 0'a inince bir Shopify Flow ürünü TASLAĞA çekiyor → 'stoksuzlar da vitrinde' politikasıyla çelişir"*

`activate_priced_drafts.ps1` bu sorunu çözmek için görselli+fiyatlı ürünleri geri aktif eder, ama **görselsiz ürünlere dokunmaz** çünkü Flow onları tekrar geri çeker.

### Çözüm Adımları (Shopify Admin'de yapılmalı)

**Adım 1**: Shopify Admin'e girin:
```
https://8t0pzm-g1.myshopify.com/admin/apps/shopify-flow
```

**Adım 2**: Aktif workflow'lardan "product" tetikleyicisi olan, ürünleri draft yapan kuralı bulun.

**Adım 3**: İki seçenek:
- **a)** Flow'u tamamen devre dışı bırakın
- **b)** Flow koşuluna istisna ekleyin: görselsiz ama fiyatlı ürünleri draft yapmasın

**Adım 4**: Flow düzeltildikten sonra, mevcut draft Hartje ürünlerini aktif etmek için:
```powershell
pwsh -File activate_hartje.ps1
```
(Bu script aşağıda "Yardımcı Komutlar" bölümünde tanımlanmıştır.)

### Alternatif Çözüm
Flow'a dokunmadan Hartje ürünlerine görsel eklemek. Görseller eklendiğinde `activate_priced_drafts.ps1` (daily_sync içinde) otomatik olarak ürünleri aktif eder.

---

## 8. Hartje Ürün Görselleri (ÖNCELİKLİ İŞ)

298 Hartje ürünü görselsiz eklendi. **Shopify Flow görselsiz ürünleri otomatik draft yapıyor, bu yüzden görseller eklenmeden ürünler sitede GÖRÜNMEZ.**

### Görsel Kaynakları

| Kaynak | URL | Not |
|--------|-----|-----|
| Hartje bayi portalı | `meinhartje.com` (SSO: `sso.hartje.de`) | Lazy-loading var, liste sayfasında `<img src="">` boş. Detay popup'ında görsel yükleniyor. |
| Conway resmi | `conway-bikes.de` | Yüksek çözünürlük görseller |
| Excelsior resmi | `excelsior-bikes.de` | Yüksek çözünürlük görseller |
| Noxon resmi | `noxon-bikes.de` | Yüksek çözünürlük görseller |
| Victoria resmi | `victoria-ebike.de` | Yüksek çözünürlük görseller |

### Görsel Yükleme (Shopify API)
```powershell
# URL ile yükleme (Shopify kendisi indirir)
$body = @{ image = @{ src = "https://example.com/bike.jpg" } } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/products/$productId/images.json" `
  -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'

# veya base64 ile yükleme
$body = @{ image = @{ attachment = $base64String; filename = "bike.jpg" } } | ConvertTo-Json
```

### Hartje Portal Scrape Stratejisi
1. `meinhartje.com`'a SSO ile giriş yap
2. Ürün listesinde her ürünün artNr'si (SKU) kartın altında görünür
3. Ürün kartına tıklayınca popup açılır — popup'taki `<img>` tag'ından görsel URL'i alınabilir
4. `data/hartje_import_data.csv`'deki `artNr` ile Shopify'daki ürünü SKU üzerinden eşleştir
5. Shopify API ile görseli yükle

Referans: `import_new_accell.ps1` ve son commit (`901f505 Eksik urun resimlerini tamamla: KB OriginalImages -> base64 yukleme`) görsel yükleme kodu örnekleri içerir.

---

## 9. Eksik / Yapılacak İşler Özeti

| # | İş | Öncelik | Durum |
|---|-----|---------|-------|
| 1 | Shopify Flow düzeltmesi (görselsiz ürünleri draft yapan kural) | KRİTİK | Shopify Admin'de yapılmalı |
| 2 | Hartje ürün görselleri (298 ürün) | KRİTİK | Görselsiz = sitede görünmez |
| 3 | Hartje stok senkronizasyonu | DÜŞÜK | Portal API yok, stok filtresi yok. Sabit stok=5 ile çalışıyor |
| 4 | QWIC stok senkronizasyonu (dealer portal stok filtresi) | ORTA | `dealer.qwic.nl` sağ üstte stok filtresi var |
| 5 | QWIC Accu Upgrade ürünü oluşturma | ORTA | `patch_qwic_battery.ps1` ile 422 hatası aldı, debug edilmeli |

---

## 10. QWIC Batarya Haritası

`patch_qwic_battery.ps1` içinde sabit kodlanmış batarya bilgisi var. Kaynak: `qwic.eu` ürün sayfalarındaki teknik özellikler.

| Model | Dahil Batarya | Upgrade Seçeneği | Upgrade Fiyatı |
|-------|--------------|-------------------|----------------|
| Signal | 360 Wh | yok | — |
| Echo Daily | 500 Wh | 756 Wh | €200 |
| Inter Essential | 400 Wh | 540 Wh | €200 |
| Inter Plus | 400 Wh | 540 Wh | €200 |
| Inter Tour | 400 Wh | 540 Wh | €200 |
| Inter Daily | 400 Wh | 540 Wh | €200 |
| Elan Daily | 500 Wh | 625 Wh | €200 |
| Elan Flow | 500 Wh | 625 Wh | €200 |
| Elan Tour | 500 Wh | 625 Wh | €200 |
| Mira Daily | 756 Wh | yok | — |
| Mira Tour | 756 Wh | yok | — |
| Atlas Comfort | 756 Wh | yok | — |
| Atlas Tour | 756 Wh | yok | — |
| Atlas Track | 756 Wh | yok | — |

Yeni QWIC modeli eklendiğinde bu haritaya eklenmeli ve `patch_qwic_battery.ps1 -Apply` çalıştırılmalıdır.

---

## 11. Hızlı Başlangıç

```bash
# 1. Repo'yu klonla
git clone https://github.com/Mervetek/zaandambicycle-sync.git
cd zaandambicycle-sync

# 2. sync.env dosyasını oluştur (mağaza sahibinden al)
# Format: yukarıdaki "sync.env dosyası" bölümüne bak

# 3. Günlük senkronu test et
pwsh -File daily_sync.ps1
# Loglar logs/ dizininde oluşur

# 4. Hartje import (kuru çalışma → gerçek)
pwsh -File import_hartje.ps1 -Brand All          # sadece ekrana basar
pwsh -File import_hartje.ps1 -Brand All -Apply    # Shopify'a yazar

# 5. QWIC batarya seçenekleri
pwsh -File patch_qwic_battery.ps1                 # kuru çalışma
pwsh -File patch_qwic_battery.ps1 -Apply          # Shopify'a yazar

# 6. QWIC stok güncelleme
pwsh -File update_qwic.ps1                        # kuru çalışma
pwsh -File update_qwic.ps1 -Apply                 # Shopify'a yazar
```

---

## 12. Yardımcı Komutlar

### Tüm Hartje ürünlerini aktif + publish yap
Flow düzeltildikten sonra veya görseller eklendikten sonra kullanılır:
```powershell
# activate_hartje.ps1 olarak kaydedin veya doğrudan çalıştırın
. .\_load_env.ps1
$shop = $env:SHOPIFY_SHOP; $api = '2024-10'
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{
    grant_type='client_credentials'; client_id=$env:SHOPIFY_CLIENT_ID; client_secret=$env:SHOPIFY_CLIENT_SECRET
} | ConvertTo-Json) -ContentType 'application/json').access_token
$h = @{ 'X-Shopify-Access-Token' = $tok }
$pubGid = 'gid://shopify/Publication/338868208003'
$pubMut = 'mutation($id:ID!,$input:[PublicationInput!]!){publishablePublish(id:$id,input:$input){userErrors{message}}}'

foreach ($vendor in 'Conway','Victoria','Excelsior','Noxon') {
    $url = "https://$shop/admin/api/$api/products.json?limit=250&vendor=$vendor&status=draft&fields=id,title"
    while ($url) {
        $r = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60
        foreach ($p in ($r.Content | ConvertFrom-Json).products) {
            # Aktif yap
            $null = Invoke-RestMethod -Method Put -Uri "https://$shop/admin/api/$api/products/$($p.id).json" `
                -Headers $h -Body (@{product=@{id=$p.id;status='active'}}|ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 30
            # Online Store'a publish
            $pubBody = @{query=$pubMut;variables=@{id="gid://shopify/Product/$($p.id)";input=@(@{publicationId=$pubGid})}} | ConvertTo-Json -Depth 6
            $null = Invoke-RestMethod -Method Post -Uri "https://$shop/admin/api/$api/graphql.json" `
                -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($pubBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
            Write-Host "[OK] $($p.title)"
            Start-Sleep -Milliseconds 400
        }
        $url = $null
        $lnk = "$($r.Headers['Link'])"; if ($lnk -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
    }
}
```

### Marka bazlı ürün sayısını kontrol et
```powershell
. .\_load_env.ps1
$shop = $env:SHOPIFY_SHOP; $api = '2024-10'
$tok = (Invoke-RestMethod -Method Post -Uri "https://$shop/admin/oauth/access_token" -Body (@{
    grant_type='client_credentials'; client_id=$env:SHOPIFY_CLIENT_ID; client_secret=$env:SHOPIFY_CLIENT_SECRET
} | ConvertTo-Json) -ContentType 'application/json').access_token
$h = @{ 'X-Shopify-Access-Token' = $tok }
foreach ($v in 'Conway','Victoria','Excelsior','Noxon','QWIC','Batavus','Sparta','Cortina') {
    $c = (Invoke-RestMethod -Uri "https://$shop/admin/api/$api/products/count.json?vendor=$v" -Headers $h).count
    Write-Host ("{0,-12} {1} urun" -f $v, $c)
}
```

---

## 13. Bilinen Tuzaklar

| Tuzak | Açıklama | Çözüm |
|-------|----------|-------|
| PowerShell 7 `Headers['Link']` | pwsh 7'de HTTP yanıt header'ı dizi döner, `$Matches`'i doldurmaz | `"$($resp.Headers['Link'])"` ile string'e çevir |
| Türkçe locale `[A-Z]` | Türkçe'de case-insensitive `[A-Z]` regex `I` harfini eşlemez (`I→ı` dönüşümü) | `-cmatch` kullan (case-sensitive match) |
| Shopify Flow görselsiz draft | Görselsiz ürünler otomatik draft yapılıyor | Bölüm 7'ye bak |
| `inventory_levels/set` vs `adjust` | `set` mutlak değer atar, `adjust` fark ekler | Import'ta `adjust`, senkronda `set` kullanılır |
| Shopify `status=active` ≠ sitede görünür | Ürün aktif olsa bile `publishablePublish` ile kanala yayınlanmalı | Online Store Publication GID ile publish et |
| Rate limiting | Shopify API saniyede ~2 istek kabul eder | Her istek arası 300-500ms `Start-Sleep` |
| Accell rate-limit (200-boş yanıt) | Eşzamanlı sorgu varsa Accell boş yanıt dönüyor | `daily_sync.ps1`'deki ikinci geçiş mekanizması |
