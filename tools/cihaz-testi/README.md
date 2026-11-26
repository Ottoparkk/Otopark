# P2 test tezgahı

Uygulamayı Paycell Sunmi P2'deymiş gibi çalıştırır ve bir Personel'in
hissedeceğini ölçer: her ekranın kaç saniyede kullanılabilir olduğu, ne kadar
bellek tuttuğu, hata çıkıp çıkmadığı. Salt okur: plaka yazmaz, düğmeye basmaz,
veritabanına bir şey yazmaz. Bağımlılık yok (Node 22+).

## Çalıştırma

```
npm run build
node tools/cihaz-testi/p2_tezgahi.mjs
```

Personel ekranlarını ölçmek için (pencerede bir **Personel** hesabıyla siz
giriş yaparsınız; giriş bir kez yapılır, profil saklanır). Giriş'te plaka
alanına `34ABC123`, Çıkış'ta aramaya `34` harf harf yazılır; Enter'a
basılmaz, bilet açılmaz:

```
node tools/cihaz-testi/p2_tezgahi.mjs --derle --chrome tools/cihaz-testi/chromium/chrome-win64/chrome.exe --elle-giris
```

`--derle` uygulamayı kaynak haritalarıyla `tools/cihaz-testi/derleme/`
klasörüne derler; rapordaki profil o zaman yavaş yeri dosya ve satırla
gösterir (`src/features/gise/Cikis.tsx:312`). Her ekran için: kullanılabilir
olma süresi, yazarken gecikme, ana iş (kod / yerleşim / stil) ve en çok zaman
alan dosyalar ile yerler.

P2'nin gerçek tarayıcısıyla (Chrome 119, Android 7'nin son sürümü):

```
node tools/cihaz-testi/p2_tezgahi.mjs --chrome tools/cihaz-testi/chromium/chrome-win64/chrome.exe
```

Rapor `tools/cihaz-testi/p2-sonuc.txt` dosyasına yazılır ve Not Defteri'nde
açılır (`--sessiz` açmaz).

Seçenekler: `--cpu 6` (daha yavaş CPU), `--dist <klasör>` (başka derleme),
`--url <adres>` (yayındaki site; kod parçası kontrolü yapılmaz), `--rapor <dosya>`.

## Neyi taklit eder, neyi edemez

| P2 | Tezgah |
|---|---|
| Chrome 119 | Gerçek, `--chrome` ile Chromium 119 verilirse. Kurulu Chrome ile değil. |
| Cortex-A53 1.5 GHz | DevTools CPU yavaşlatma, varsayılan 4x (Lighthouse'un aynı sınıf Moto G4 ayarı). Bu PC'nin hızına bağlı bir yaklaşık değer. |
| 4G | "Yavaş 4G": 150 ms, 1.6 Mbit/s indirme, 750 kbit/s yükleme. |
| 1 GB RAM | **Sınırlanamaz.** Chrome düşük-RAM modunda çalışır; JS belleği raporlanır ve bir sınırla karşılaştırılır. |
| 720x1440 ekran | 360x720, piksel oranı 2, dokunmatik. |

Rapordaki iyi / kabul sınırları tahmindir, cihazda ölçülmedi. Gerçek cihaz
son sözü söyler.

## Arkada kalanlar

- Tarayıcı profili: `%TEMP%\otopark-p2-profil-*` (giriş oturumu burada).
- İndirilen Chromium: `tools/cihaz-testi/chromium/` (git'e girmez).
- `--derle` çıktısı: `tools/cihaz-testi/derleme/` (git'e girmez).
