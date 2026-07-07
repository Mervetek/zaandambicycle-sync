$dataDir = Join-Path $env:USERPROFILE "Desktop\claude\ZaandamBicycle\data"
$rows = Import-Csv "$dataDir\stok_listesi.csv"
$vars = Import-Csv "$dataDir\variations.csv"
$varsByProduct = $vars | Group-Object product_id -AsHashTable -AsString

# --- 1) Duzeltme listesi: 68 tutarsiz urun, onerilen aksiyon + guven ---
$fix = foreach ($r in ($rows | Where-Object { $_.tutarsizlik -eq 'EVET' })) {
    $pv = $varsByProduct["$($r.id)"]
    $explicitOut  = @($pv | Where-Object { $_.availability -match 'Uitverkocht' }).Count
    $explicitBack = @($pv | Where-Object { $_.availability -match 'nabestelling' }).Count
    $defaultIn    = @($pv | Where-Object { $_.is_in_stock -eq 'True' -and $_.availability -notmatch 'nabestelling' }).Count
    $total = if ($pv) { $pv.Count } else { 0 }

    $key = "$($r.site_gosterimi)->$($r.stok_durumu)"
    switch ($key) {
        'VAR->YOK' {
            $aksiyon = "Urun (parent) durumunu 'outofstock' yap"
            $guven = 'YUKSEK'
            $neden = "Tum secenekler acikca 'Uitverkocht' isaretli ama urun stokta gorunuyor. Musteri hayal kirikligi / iade riski."
        }
        'VAR->ON_SIPARIS' {
            $aksiyon = "Urun durumunu 'onbackorder' yap"
            $guven = 'YUKSEK'
            $neden = "Secenekler sadece on siparisle alinabiliyor ama urun normal stokta gorunuyor."
        }
        'YOK->ON_SIPARIS' {
            $aksiyon = "Urun durumunu 'onbackorder' yap"
            $guven = 'YUKSEK'
            $neden = "Secenekler onizsiparisle satilabilir durumda ama urun 'uitverkocht' gorunuyor. SATIS KAYBI."
        }
        'ON_SIPARIS->VAR' {
            $aksiyon = "Urun durumunu 'instock' yap (VEYA secenek stogu yanlissa secenekleri duzelt)"
            $guven = 'ORTA'
            $neden = "Bazi secenekler normal stokta gorunuyor ama urun on-siparis etiketli."
        }
        'YOK->VAR' {
            $aksiyon = "KARAR GEREKLI: gercekten stok varsa urunu 'instock' yap; yoksa secenekleri 'outofstock' yap"
            $guven = 'DUSUK - dogrulama gerekli'
            $neden = "Urun listede 'uitverkocht' ama urun sayfasindan bedenler satin alinabiliyor. Ya stok geldi statu guncellenmedi (SATIS KAYBI) ya da secenek stogu hic islenmedi (YANLIS SATIS riski)."
        }
        default { $aksiyon = 'Incele'; $guven = 'DUSUK'; $neden = $key }
    }

    [PSCustomObject]@{
        id = $r.id; urun_adi = $r.urun_adi; marka = $r.marka
        site_gosterimi = $r.site_gosterimi; gercek_durum = $r.stok_durumu
        secenek_toplam = $total; acik_uitverkocht = $explicitOut; on_siparis = $explicitBack; stokta_gorunen = $defaultIn
        stokta_bedenler = $r.stokta_bedenler
        onerilen_aksiyon = $aksiyon; guven = $guven; neden = $neden
        sku_listesi = $r.sku_listesi; url = $r.url
    }
}
$fix | Sort-Object guven, marka, urun_adi | Export-Csv "$dataDir\duzeltme_listesi.csv" -NoTypeInformation -Encoding utf8

Write-Host "=== Duzeltme listesi: $($fix.Count) urun ==="
$fix | Group-Object guven | Format-Table Name, Count -AutoSize
$fix | Group-Object onerilen_aksiyon | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize -Wrap

# --- 2) Dogrulama checklisti: VAR gorunen bisikletler (adet takibi yok, gercek stok bilinmiyor) ---
$check = $rows | Where-Object { $_.bisiklet_mi -eq 'EVET' -and $_.stok_durumu -eq 'VAR' } | ForEach-Object {
    $kruitbosch = if ($_.marka -in 'Cortina','Alpina','Raleigh') { 'EVET' } else { 'HAYIR' }
    [PSCustomObject]@{
        marka = $_.marka; urun_adi = $_.urun_adi; fiyat_eur = $_.fiyat_eur
        stokta_gorunen_bedenler = $_.stokta_bedenler
        sku_listesi = $_.sku_listesi
        kruitbosch_markasi = $kruitbosch
        gercek_stok_var_mi = ''   # elle / Kruitbosch API ile doldurulacak
        url = $_.url; id = $_.id
    }
}
$check | Sort-Object @{e={$_.kruitbosch_markasi}; Descending=$true}, marka, urun_adi | Export-Csv "$dataDir\dogrulama_checklist.csv" -NoTypeInformation -Encoding utf8
Write-Host "=== Dogrulama checklisti: $($check.Count) bisiklet ==="
$check | Group-Object kruitbosch_markasi | Format-Table Name, Count -AutoSize
$check | Group-Object marka | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
