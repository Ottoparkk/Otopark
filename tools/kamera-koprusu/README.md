# Kamera köprüsü

Grabs a cropped plate photo from an IP camera on a computer at the car park and
posts it to `kamera-webhook`, which reads it with **the same model the phone app
uses**. **Nothing in this folder is part of the web app** — it is not built,
typechecked or deployed with it. It runs on hardware you own.

The camera never touches the internet. It talks to this machine over the LAN;
this machine talks out. That is the whole security argument for the bridge.

## Why it does not read plates itself

An earlier version ran YOLOv8 + EasyOCR on this box. Both halves are gone, for
different reasons:

- **The OCR** is gone because a second engine is a second accuracy question
  nobody has measured on Turkish plates, while the server's engine is the one
  that gets tuned, logged and improved. The camera path and the phone path now
  read plates identically, by construction.
- **The detector** is gone because Ultralytics' licence (AGPL-3.0) requires an
  enterprise licence for proprietary internal use — and because it was not
  needed. The camera is fixed, aimed at one lane, at cars that *stop* at a
  barrier, so the plate lands in the same rectangle of every frame. A crop box
  you configure once does the same job with no model, no GPU and no licence.

What remains is the part that was actually carrying the accuracy: **the crop.**
Measured on one car photographed twice, far away it read three of eight
characters wrong and close it read perfectly. The crop is not a bandwidth
optimisation.

## What you need

- A computer on the same network as the camera. An old laptop is the best
  choice available: it has a screen for diagnosis and the UPS is already inside
  it. A Raspberry Pi is now genuinely enough — nothing here does inference.
- The camera's username and password. **Not** its RTSP URL — the installer
  works that out.
- Nothing else. The packaged build carries its own Python; only building the
  package needs one installed (3.10+).

## Kurulum — paketlenmiş sürüm (önerilen)

Otoparktaki bilgisayara **hiçbir şey kurulmuyor**: ne Python, ne `pip`, ne
terminal. Bu üçü, teknik olmayan birinin kurulumu bırakmasına yol açan
adımlardı.

1. `OtoparkKamera-<sürüm>.zip` dosyasını indirin
2. **ZIP'ten çıkarın** — içinden doğrudan çalıştırmak sessizce başarısız olur
3. `OtoparkKamera.exe`'ye çift tıklayın, UAC sorusuna Evet deyin

Dört soru sorar, ikisi kameranın kendi kullanıcı adı ve şifresi:

1. **Kurulum kodu** — uygulamada Yönetim → Kamera kurulumu → "Yeni kamera"
   ile üretilen `XXXXX-XXXXX` biçiminde kısa bir kod. `kurulum-kodu.txt`
   .exe'nin yanına konmuşsa hiç sorulmaz. Kod okunduktan sonra dosyanın
   silinmesi teklif edilir (varsayılan: evet)
2. **Kamera** — ağda kendisi arar; şifreyi girin, RTSP adresini marka marka
   deneyerek bulur (Hikvision, Dahua, VIGI, Uniview, Axis, Reolink, ONVIF).
   1.2.1: şifre taramadan ÖNCE tek bir istekle sınanır — tarama her yolu ayrı
   bir giriş denemesi olarak yapar ve tek bir yazım hatası kamerayı (Dahua beş,
   Hikvision yedi yanlıştan sonra) kilitlerdi. Kabul edilmezse yeniden sorulur;
   iki soruda da Enter = aynı bilgilerle devam (kontrol asla tek başına
   durdurmaz). Elle yazılan RTSP adresi kabul edilmeden önce denenir.
3. **Kırpma kutusu** — tarayıcıda canlı görüntü açılır, plakanın etrafını
   **fareyle sürüklersiniz**. Kutu 200 pikselin altına düşerse kırmızıya döner
4. **Test** — bağlantı ve gizli anahtar doğrulanır; 1.2.1'den beri bu
   bilgisayarın saati de sunucununkiyle karşılaştırılır (bir dakikadan fazla
   fark = durur, ne yapılacağını söyler)

Kurulum, köprü başlayıp kameraya bağlandıktan **ve sunucu ilk kalp atışını
kabul ettikten** sonra "tamamlandı" der (1.2.1). Program `OtoparkKamera`
klasörünün kendisinden çalışıyorsa (ZIP'in klasörü, içinde yalnızca paket
dosyaları) o klasör yalnızca yöneticilerin değiştirebileceği hâle getirilir:
görev oradaki programı SYSTEM olarak çalıştırıyor. Başka bir klasörde (Masaüstü,
İndirilenler) izinlere DOKUNULMAZ, yalnızca uyarılır.

### Kurulum kodu neden var

`KAMERA_WEBHOOK_SECRET` yalnızca Edge Function ortamında duruyor ve
`.env.example` onun bir `VITE_` değişkenine dönüşmesini yasaklıyor — yani
uygulama onu OKUYAMAZ ve içinde anahtar taşıyan bir kod üretemez. Değiş tokuş
bu yüzden sunucuda, `kamera-eslestir` içinde oluyor.

Köprünün elinde kalan şey ortak anahtar DEĞİL, **o kameraya özel** bir anahtar;
veritabanında yalnızca sha256'sı duruyor. Üç sonucu var: veritabanını okuyan
biri çalışan bir kimlik elde edemez, bir kamera ötekine dokunmadan iptal
edilebilir, ve her şerit kendi kalp atışını vurduğu için **çıkış kamerasının
ölümü artık görünür** (önceden giriş köprüsü tek genel damgayı taze tutuyordu
ve ölen çıkış kamerası hiç uyarı üretmiyordu).

Kod 15 dakika geçerli, **tek bir kameraya** bağlı ve 50 bitlik. Kamera hiç
bağlanmadıysa aynı kod yeniden değiş tokuş edilebilir: cevabı yolda kaybolan
bir kurulum, yoksa hem kodu harcar hem de anahtarını kimsenin bilmediği ölü
bir cihaz bırakırdı. Yeniden deneme yeni cihaz AÇMAZ; aynı cihazın anahtarını
değiştirir ve eskisi o anda ölür. Kameranın ilk kalp atışından sonra kod biter.

Şeridi kodu üreten kişi seçer; kuruluma sorulmaz ve **asla tahmin edilmez** —
sunucudan anlaşılmaz bir şerit gelirse kurulum durur, çünkü giriş sanılan bir
çıkış kamerası giden araçlara bilet açar ve bunu kimse fark etmez. Aynı kural
sunucuda da tutuluyor: eşleştirilmiş kameranın şeridi **kendi satırından**
okunur ve başka şerit söyleyen bir istek 409 ile reddedilir (ayar dosyası elle
değiştirilse bile). Eski biçimli bir kodda şerit eksikse sihirbaz onu sorar,
`GIRIS` varsaymaz.

### Tek kapı (`ORTAK`)

Üçüncü bir şerit var: `ORTAK` — araçların **aynı kapıdan girip çıktığı**
otopark. Köprü için hiçbir şey değişmez (gördüğü aracı fotoğraflar, `yon:
ORTAK` ile gönderir); fark sunucudadır. Şerit yönü söyleyemediği için
`kamera-webhook` olayı `kamera_tek_kapi`'ye (037) verir ve karar **bilet
durumundan** çıkar:

| Plaka… | Karar |
|---|---|
| açık bileti var, bilet az önce açıldı (varsayılan 3 dk) | yok sayılır — araç hâlâ kameranın önünde |
| açık bileti var, daha eski | çıkış: yalnızca "kapıda" damgası |
| bileti az önce kapandı (varsayılan 5 dk) | yok sayılır — ödeyip çıkan araç |
| içerideki bir plakaya bir karakter uzak | Çözülmemiş kayıtlar (`YON_BELIRSIZ`) — tahmin edilmez |
| okunamadı (araç var, plaka okunmadı) | Çözülmemiş kayıtlar (`OKUNAMADI`, 039) — girdi mi çıktı mı bilinmez |
| hiçbiri | giriş: bilet açılır |

Cevap gövdesi `karar` ve `sebep` taşır ve köprü cevabı kayda yazdığı için her
karar `kopru-ortak.log` içinde okunabilir (`"karar":"YOKSAY","sebep":"YENI_GIRIS"`).

Şerit listesi tek yerde: `gunluk.SERITLER`. Kurulum, kaldırma ve köprü oradan
okur; `ORTAK` hiçbir yerde `GIRIS`e yuvarlanmaz. 1.0.0 kurulum programı
`ORTAK`ı tanımaz ve "şerit anlaşılmadı" diye durur — tek kapı için **1.1.0**
gerekir.

Giriş süresi 3 dakikanın altına indirilemez. Köprü bir aracı gönderdikten sonra
o araç gidene kadar susar, ama kadrajda bir şey kıpırdayıp yeniden durulursa
(önünden geçen biri, biraz ilerleyen araç) **aynı aracı yeniden gönderir** —
bu bir hata değil, araç kaçırmamak için böyle. Tek kapıda o ikinci gönderim,
bilet 3 dakikadan eskiyse "çıkıyor" sayılır. Yani kameranın önünde 3 dakikadan
uzun duran, az önce girmiş araç yanlışlıkla "Kapıda" işaretlenebilir (para
hareket etmez, yalnızca işaret). Kamerayı araçların **kısa bir an durduğu**
noktaya (köprü plakayı o duruşta çeker) çevirin; sıra beklenen ya da park
edilen bir yere değil.

Sihirbaz yeniden çalıştırıldığında `kopru-<şerit>.json` içindeki kimliği
sunucuya sorar; hâlâ geçerliyse **yeni kod istemeden** o şeridi yeniden kurmayı
teklif eder. Sorunun varsayılanı **hayır**, ve yanında yeni bir
`kurulum-kodu.txt` varsa hiç sorulmaz: ikinci şeridi kurmaya gelen kişinin
Enter'a basması, ilk şeridin kimliğini yeni kameraya bağlamamalı. Eşleştirme
yalnızca `https` üzerinden yapılır.

Bağlantı testi ve bu yoklama `x-kamera-deneme: 1` başlığı taşır; sunucu o
istekte kimliği doğrular ama **kalp atışı vurmaz**. Uygulamadaki "Çalışıyor"
bu yüzden köprünün KENDİSİ çalıştığında görünür (kurulumun ikinci adımında
değil), ve aynı kodla yeniden eşleştirme penceresi kurulum boyunca açık kalır.

Köprünün şerit için **varsayılanı yok**: `YON` verilmeden başlamaz (eskiden
`GIRIS`e düşüyordu). Sunucu bir aracı "bu kamera öbür şeride eşleştirilmiş"
diye reddederse (409 + `SERIT_UYUSMAZ`) köprü bunu ayrı bir satırla yazar ve
Durum ekranı `ŞERİT UYUŞMUYOR` der; sıradan bir 409 arıza sayılmaz.

Elle kurulum yolu duruyor: internetsiz ya da sunucu tarafı henüz hazır olmayan
bir kurulumda webhook adresi + `KAMERA_WEBHOOK_SECRET` hâlâ kabul ediliyor, ve
`kamera-webhook` o yolu **birebir eskisi gibi** değerlendiriyor (önce ortak
anahtar, veritabanına hiç dokunmadan).

Sonra kendisi: ayarları `C:\ProgramData\Otopark\` içine yazar (yalnızca SYSTEM
ve yöneticiler okuyabilecek şekilde — dosya **önce** kısıtlanır, anahtar sonra
yazılır; izinler SID ile verilir ki Windows'un dili fark etmesin, ve kısıtlama
tutmazsa sihirbaz bunu söyler), görev planlayıcıya ekler, **uykuyu ve
dizüstü kapağı ayarını kapatır**, sonra köprünün gerçekten başladığını kayıt
dosyasından **doğrular**.

O üç güç ayarı kurulumları haftalar sonra sessizce öldüren şeylerdir ve hiçbiri
teknik olmayan birinin aklına gelmez — özellikle kapak ayarı, çünkü önerilen
kutu eski bir dizüstü ve ilk yapılan şey kapağını kapatmaktır.

Bağlantı testi bilerek **fotoğraf göndermez**: gerçek bir kare gerçek bir bilet
açardı ve kurulum, kasada silinmesi gereken bir kayıt bırakmamalı.

Son adım "görev oluşturuldu" demekle yetinmez. Görev kurulup süreç kameraya
bağlanamadan ölebilir ve `schtasks` bunu **başarı** olarak bildirir; kurulumdan
çıkıp gitmiş birine bunu söyleyen hiçbir şey olmazdı.

### Çalışıyor mu?

`OtoparkKamera.exe`'ye tekrar çift tıklayın → **Durum**.

```
  ── GIRIS şeridi ──────────────────────────────
     Kamera       : rtsp://admin:•••@10.0.0.42:554/stream1
     Otomatik başlatma: kurulu
     Son hareket  : 12 saniye önce
     Durum        : ÇALIŞIYOR
     Bugün        : 143 gönderim, 0 reddedilme
```

Beş koşulun **beşi birden** aranır, çünkü her biri ötekinin kör noktasını
kapatıyor:

- **kamera görüntü veriyor mu** — kamerası olmayan köprü ölmez: açılışta
  kamerayı bekler, çalışırken yeniden bağlanır ve her denemede bir satır yazar,
  yani kayıt taze kalır. Durum ekranı `KAMERA YOK` der

- **sunucu köprüyü reddetmiyor mu** — uygulamadan kaldırılan ya da devre dışı
  bırakılan kameranın köprüsü çalışmaya ve kayıt yazmaya devam eder; her isteği
  401 alır. Köprü bunu sabit bir satırla kaydeder (`sunucu kimliği reddetti`)
  ve durum ekranı `KİMLİK REDDEDİLDİ` der. 403 için ayrı: `KAMERA GİRİŞİ KAPALI`

- **kayıt dosyası taze mi** — köprü beş dakikada bir "çalışıyor" satırı yazar;
  boş bir otoparkta başka hiçbir şey yazmayabilir ve o sessizlik ölü bir
  köprüden ayırt edilemezdi
- **son işaret "durdu" değil mi** — başlar başlamaz ölen köprü de dosyayı
  tazeler, yani tek başına tazelik ölçütü onu on beş dakika "ÇALIŞIYOR"
  gösterirdi
- **görev kurulu mu** — şu an koşan ama açılışta dönmeyen bir köprü, ilk
  elektrik kesintisinde sessizce biter

Yanlış yönde yanılan bir sağlık göstergesi, göstergesizlikten kötüdür: kimse
bakmayı bırakmaz, herkes yanlış cevaba güvenir.

### Kayıtlar

```
C:\ProgramData\Otopark\kayit\kopru-giris.log
```

Kurulan hâlinde köprüyü Görev Zamanlayıcı **SYSTEM** olarak başlatıyor ve o
sürecin konsolu yok — `print()` çıktısı hiçbir yere gitmiyordu. "İlk günün
kayıtlarını izleyin" tavsiyesinin karşılığı ancak bu dosyayla var.

2 MB'de döner, iki yedek tutulur (~6 MB tavan). Klasör yalnızca SYSTEM ve
yöneticilere açık: kayıt, sunucunun okuduğu plakaları içerebiliyor.

### Kaldırma

`OtoparkKamera.exe` → **Kaldır**. Görevi siler ve ayar dosyasını **gizli
anahtarıyla birlikte** kaldırır. Kayıtlar bilerek durur — arızayı anlamaya
çalışan kişinin elindeki tek iz. Güç ayarları da durur; bilgisayarı başka bir
iş için kullanacaksanız Güç Seçenekleri'nden geri alın.

## Paketi üretmek (geliştirici)

```bash
pip install pyinstaller
python paketle.py
```

`dagitim/OtoparkKamera-<sürüm>-<tarih>.zip` (~60 MB) üretir ve SHA-256 özetini
yazar. Özeti dağıtımla birlikte verin: indirilen dosyanın yolda değişmediğini
doğrulamanın tek yolu.

- **`--onedir`, `--onefile` değil.** Tek dosyalı sürüm her açılışta ~120 MB'ı
  geçici klasöre açıyor; köprü bir servis olarak yeniden başlıyor ve bu her
  seferinde saniyeler demek. Ayrıca kendini geçici klasöre açan .exe, virüs
  tarayıcılarının en çok yanlış pozitif verdiği kalıp.
- **UPX kapalı.** Sıkıştırılmış bölüm ikinci bir şüphe sebebi, kazanç birkaç
  on MB.
- **`--uac-admin`.** Kurulum görev oluşturuyor, uyku ayarlarını değiştiriyor ve
  ProgramData'ya yazıyor. Manifest ile UAC kendiliğinden çıkıyor; "sağ tıklayıp
  yönetici olarak çalıştırın" adımı atlanınca kurulumun yarısı **sessizce**
  başarısız oluyordu.

**İmzalanmamış.** SmartScreen ilk çalıştırmada mavi ekran gösterir ("Daha fazla
bilgi" → "Yine de çalıştır"); `OKU-BENI.txt` bunu anlatıyor. Kod imzalama
sertifikası (~$200-400/yıl) bunu kaldırır ve alınmadı.

Aşağıdaki elle kurulum yolu duruyor — paketlenmiş sürüm onun yaptığını
otomatikleştirir, yerine geçmez. Kaynaktan çalıştırmak için:

```bash
pip install -r requirements.txt
python kurulum.py            # Windows'ta: yönetici olarak
```

## Elle kurulum — kırpma kutusunu ölçmek

*Sihirbazı kullandıysanız bu bölümü atlayın; kutuyu sizin için o seçti.*

```bash
python kopru.py --kare
```

Saves `kare.jpg` and prints the frame size. Open it, measure the rectangle the
plate sits in when a car is stopped at the barrier, and pass it as `x,y,w,h` in
pixels. Frame it **generously** — a box cropped to the plate's exact edges
loses the context the model uses, and one that only just fits will miss a tall
van or a low sports car.

```bash
export KIRPMA="820,540,600,220"
python kopru.py --test
```

Saves `kirpik.jpg` — confirm the plate is actually inside it — and then prints
live `hareket` values. Watch them with the lane empty and with a car pulling
in: that tells you what to set `HAREKET_ESIGI` (moving) and `DURGUN_ESIGI`
(still) to, instead of guessing.

If `kirpik.jpg` comes back under 200 px on its long edge, the bridge warns you.
That is the size at which the model's own documentation says reads become
unreliable — move the camera closer or zoom in; no amount of prompt tuning
recovers pixels that were never captured.

## Skipping the empty lane (learned automatically since 1.2.0)

A car **arriving** and a car **leaving** look identical to the bridge — motion,
then stillness — so it photographs the empty lane after every departure, and
every vehicle costs two reads instead of one.

**Since 1.2.0 the bridge learns the empty lane by itself.** When it sends a
photo of the empty lane, the server's model answers "no vehicle at all"
(`arac_yok` in the webhook's 422). The bridge keeps a tiny 160×120 grey copy as
a *candidate*. When a later empty-lane photo gets the same answer, looks the
same, **and at least one car was read in between**, the candidate becomes a
*reference*. From then on a settled picture that matches a reference is not
sent; the log says `boş şerit — gönderilmedi (fark=…, ref=…)`.

- Up to 6 references (day, dusk, infrared night, wet road…); the one unused
  longest makes room. Kept in memory: after a restart the first departures are
  paid for again and the references come back.
- "A car read in between" is what stops one parked car with an unreadable plate,
  photographed twice, from being learned as "empty". A 422 without `arac_yok`
  ("a car I cannot read") is never learned from.
- Size-mismatched pictures are never treated as matching (the motion `fark()`
  returns 0.0 for that case; the learner refuses to compare instead).
- **Check it on installation day:** every skip logs its `fark`. Empty-lane
  matches should sit near 0, and a car must never come close to `BOS_ESIGI`
  (3.0). If anything looks borderline, set `"BOS_OGREN": "0"` in the lane's
  config file and the bridge behaves exactly like 1.1.0.
- Needs the webhook that sends `arac_yok` (deployed with the Haiku 5.5 change).
  Against an older webhook nothing is learned and nothing changes.
- `durum` shows `Boş şerit : N okundu, M atlandı` for today.

### Manual reference (still supported)

A hand-made reference works alongside the learned ones and is never dropped:

```bash
python kopru.py --bos      # run this while the lane is EMPTY
export BOS_REFERANS="bos.jpg"
```

**This cannot cause a missed vehicle, by design.** If the reference is wrong —
taken with a car in it, or in daylight and used at night — then an empty lane
also looks different from it and the bridge sends anyway. The worst case is the
behaviour you already have without it. That asymmetry is deliberate: a wasted
read costs a fraction of a cent, a missed car costs a free park.

**Worth setting for more than the money.** A photo of the empty lane also
*disarms* the bridge for `MIN_BEKLEME_SN`, so those wasted reads eat into the
window the next vehicle needs. That is why the floor is 2s and not longer; with
a reference configured the departure never fires and the question goes away.

Leave `BOS_REFERANS` unset and only the learned references are used.

## Run

```bash
export WEBHOOK_URL="https://<project-ref>.supabase.co/functions/v1/kamera-webhook"
export KAMERA_SECRET="<same value as the KAMERA_WEBHOOK_SECRET function secret>"
export RTSP_URL="rtsp://user:pass@10.0.0.42:554/stream1"
export YON="GIRIS"
export KIRPMA="820,540,600,220"
python kopru.py
```

**One process per lane.** Direction is configuration, never a guess — an exit
camera that thinks it is an entrance opens tickets for cars that are leaving.

On Windows, `set` instead of `export`, and use Task Scheduler ("run whether user
is logged on or not") instead of the systemd unit below.

### When it sends

One photo per car, taken at the moment the car **stops**: the bridge waits for
motion in the crop box and then for several still frames. That frame is both
the moment the plate is in position and the sharpest one available — a moving
car is the blurry one, and blur is what costs characters.

After a send the lane is **disarmed until that vehicle leaves the frame** — the
crop has to stop matching the one that was sent. It is not a timer, and that
distinction is load-bearing: a fixed 60s cooldown used to outlive the 12s
motion window, so the *next* car settled while sending was blocked and was
already stale by the time it lifted. Every vehicle arriving roughly 5–49s
behind another was dropped, with no ticket and nothing in `istisnalar` to find
it by.

Re-arming is an API-cost guard, not a data guard: if the same car were sent
twice, the plate resolves to the same value and the one-open-ticket-per-plate
index refuses the second. That is why an early re-arm on a lighting change is
acceptable, and why `MAX_BEKLEME_SN` can force one without risk.

**Known cost, accepted deliberately:** a car that creeps forward at the barrier
can move enough to look like it left, and get photographed again. Each repeat
is one wasted read and a 409 from the webhook — never a wrong ticket. Every
guard that would suppress it also risks suppressing a genuinely new vehicle,
and a missed car costs a free park while a repeat costs a fraction of a kuruş.

### Tuning

| Variable | Default | What it does |
|---|---|---|
| `KIRPMA` | *(none)* | `x,y,w,h` in pixels. Unset = send the whole frame, which works but reads worse. |
| `MAX_KENAR` | `1568` | Long-edge cap. Raise to `2576` only if `plaka_model` is a high-resolution model (Claude 4.7 and later). |
| `JPEG_KALITE` | `92` | Deliberately gentle — heavy JPEG makes text hard to read. |
| `HAREKET_ESIGI` | `6.0` | Above this, something is moving. |
| `DURGUN_ESIGI` | `2.0` | Below this, the scene is still. |
| `DURGUN_KARE` | `5` | Still frames required before believing the car stopped. |
| `MIN_BEKLEME_SN` | `2` | Floor between two sends. Keep it well under a plausible dwell at the barrier — see the empty-lane note above. |
| `MAX_BEKLEME_SN` | `120` | Re-arm after this even if the scene never changed. Insurance — a wedged disarm would lose every later car. |
| `SAHNE_ESIGI` | `6.0` | How different the crop must look from the sent frame before the vehicle counts as gone. |
| `BOS_REFERANS` | *(none)* | Path to an empty-lane frame from `--bos`. Optional since 1.2.0 (references are learned). |
| `BOS_ESIGI` | `3.0` | How close to a reference counts as "empty" — for learned and manual references alike. |
| `BOS_OGREN` | `1` | `0` turns empty-lane learning off (behaviour of 1.1.0). |

## Testler

```bash
python test_kopru.py            # yakalama döngüsü, 14 senaryo, ~3 dk
python test_kopru.py iki_arac   # tek senaryo
python test_kurulum.py          # kurulum tarafı birimleri, ~5 sn
```

Gerçek `main()` döngüsünü sahte bir kamera ve sahte bir ağ ile çalıştırır —
karar mantığı taklit edilmez. `requests` kurulu olmasa da koşar.

Altıncı senaryo (`gec_kamera`) açılışı tutuyor: elektrik kesintisinden sonra
bilgisayar kameradan önce açılır; köprü eskiden ilk denemede çıkıyordu ve görev
açılışta yalnızca bir kez koştuğu için biri bilgisayarı yeniden başlatana kadar
dönmüyordu. Artık kamerayı bekliyor (5 sn'den 60 sn'ye uzayan aralıklarla) ve
beklerken kalp atışı GÖNDERMİYOR — ölü kamera sunucuya canlı görünmemeli.

İlk beş senaryo da bir zamanlar araç düşüren gerçek hatalardan geldi: iki araç arka
arkaya, hız sınırı (429), yavaş webhook, bariyerde bekleyen araç, ve bariyere
ilerleyen üç araçlık kuyruk. Sabit 60 sn'lik beklemenin olduğu sürümde bunların
dördü kalıyor.

İki senaryo 1.2.1'den: `kalp_bloklamaz` — kalp atışı yakalama döngüsünde senkron
koşuyordu ve yavaş bir cevap kamerayı 10-20 sn donduruyordu; o arada gelip duran
araç hiç görülmüyordu (bu senaryo eski kodda aracı gerçekten kaçırıyordu).
`son_gonderim` — okuma servisi çökünce aynı islem_id ile dört deneme yapılır ve
yalnızca SONUNCUSU `x-kamera-son-gonderim: 1` taşır (sunucu aracı ancak o
denemede "okunamadı" kaydına çevirir, 039).

Dört senaryo boş şerit öğrenmeyi (1.2.0) tutuyor. Sahte sunucu fotoğrafa
bakıp model gibi cevap veriyor (araç → 200, boş → 422 + `arac_yok`):
`bos_ogrenme` üçüncü boş şeridin HİÇ gönderilmediğini ve üçüncü aracın yine
gönderildiğini; `bos_belirsiz` (arac_yok yok), `bos_arada_okuma_yok` (arada
okunan araç yok) ve `bos_ogren_kapali` (`BOS_OGREN=0`) hiçbir şeyin
öğrenilmediğini sınıyor.

`test_kurulum.py`'deki 99 birim testi kurulum tarafını tutuyor — ayar yükleme,
kayıt dosyası, durum ekranı, görev komutu. Orası bozulursa köprü hiç
**başlamaz** ve bunu kimse fark etmez: bariyerde sessizce duran bir süreç,
arabası olmayan bir otoparka benziyor.

Beşi, kurulumu yazarken gerçekten yapılmış hataları tutuyor:

- **`gorev_komutu` `--kopru` taşımalı.** Paketlenmiş sürümde tek bir .exe var
  ve argümansız çalıştırıldığında sihirbazı açıyor. Bu bayrak düşerse Görev
  Zamanlayıcı her açılışta SYSTEM olarak görünmez bir kurulum sihirbazı
  başlatır — `input()` bekleyen, kimsenin göremediği, köprüyü hiç
  çalıştırmayan bir süreç.
- **`durum` başlar başlamaz ölen köprüyü sağlıklı göstermemeli.** Tek ölçüt
  tazelikken ölmek de dosyayı tazeliyordu.
- **Kayıt satırları iş parçacığı başına tamponlanmalı.** `print()` metni ve
  satır sonunu ayrı çağrılarla yazıyor; yakalama döngüsü ile gönderici aynı
  anda yazınca satırlar birbirine geçiyordu.
- **Eşleştirme şeridi TAHMİN ETMEMELİ.** Sunucudan anlaşılmaz bir şerit
  gelirse kurulum durur. `GIRIS`e düşmek, çıkış kamerasının giden araçlara
  bilet açmasıyla biter ve bunu kimse fark etmez.
- **`kamera-eslestir` adresi düz `replace` ile türetilmemeli.** Eski
  kurulumlarda webhook adresi gizli anahtarı yol parçası olarak taşıyabiliyor
  (`.../kamera-webhook/<gizli>/giris`) ve düz replace onu yeni adrese de
  taşırdı.

Testlerin hatayı gerçekten yakaladığı, her düzeltme tek tek geri alınıp
sınanarak doğrulandı (9/9).

## Görev tanımı neden XML

`schtasks /create /sc onstart ...` bayraklarıyla kurulan görev Windows'un
varsayılanlarını taşır ve ikisi köprüyü sessizce durdurur (bu makinede ölçüldü):

| Varsayılan | Sonucu |
|---|---|
| `ExecutionTimeLimit = PT72H` | üç gün sonra "çok uzun koştu" diye sonlandırılır |
| `StopIfGoingOnBatteries = true` | dizüstünde elektrik bir an kesilince durur |

İkisinde de görev bir sonraki açılışa kadar geri gelmez. Bayrakla
değiştirilemedikleri için sihirbaz görevi bir XML tanımından kurar
(`kurulum.gorev_xml`): süre sınırı yok, pilde de çalışır, **ölürse bir dakika
sonra yeniden başlar**, açılışta 30 sn gecikmeyle başlar, aynı şerit için ikinci
kopya başlamaz. Yeniden kurulumda eski süreç önce durdurulur; yoksa köprü eski
ayarla koşmaya devam ederdi.

Kurulumun son adımı "köprü başladı" satırıyla yetinmez: köprü durmamış, kamerayı
açmış ve sunucu tarafından reddedilmemiş olmalı — Durum ekranıyla aynı ölçütler.
Değilse sihirbaz **"KURULUM TAMAMLANMADI"** der ve sebebi yazar.

## Kırpma sayfası

Yerel sayfa boş bir porta bağlanır (sabit 8099 doluysa sihirbaz çöküyordu),
`Host` başlığı yerel değilse hiçbir şey sunmaz ve `/kaydet` sayfaya gömülü
rastgele bir belirteç ister — aynı tarayıcıda açık başka bir site kırpma kutusunu
değiştiremez. Kare gelene kadar "Kameradan görüntü bekleniyor…" yazar; akış
koparsa yeniden bağlanır.

Eşikler **seçilen kutunun içinde** ölçülür: köprü hareketi kırpılmış görüntüde
ölçtüğü için tüm kareden çıkarılan eşik başka bir sinyalden çıkarılmış olurdu.
Kutu kaydedildikten sonra altı saniye izlenir. O sürede gerçek bir hareket
görülmediyse (çoğu zaman böyledir) eşik UYDURULMAZ: varsayılanlar (2.0 / 6.0)
korunur ve yalnızca gürültü tabanı onları aşıyorsa yukarı çekilir.

Kamera aranırken önce tek bir bağlantı denemesi yapılır; ulaşılamayan adreste on
şablon tek tek beklenmez. Her şablon denemesi OpenCV'nin açma zaman aşımıyla
6 sn'de kesilir — FFmpeg'in `stimeout` seçeneği burada işe yaramıyordu ve
cevapsız bir adreste tarama beş dakika asılı kalıyordu (ölçüldü).

## Keep it alive

The expensive failure is silent: if this process dies at 03:00, entries simply
stop being recorded, and a camera that stopped reading looks exactly like a car
park with no cars. Two things guard against it:

1. **systemd restarts it.** Save as `/etc/systemd/system/kopru.service`:

   ```ini
   [Unit]
   Description=Otopark kamera koprusu
   After=network-online.target

   [Service]
   EnvironmentFile=/etc/kopru.env
   ExecStart=/usr/bin/python3 /opt/kopru/kopru.py
   Restart=always
   RestartSec=10

   [Install]
   WantedBy=multi-user.target
   ```

   ```bash
   sudo systemctl enable --now kopru
   ```

2. **There is now a local record.** Every send, every refusal and a
   "çalışıyor" line every five minutes go to
   `C:\ProgramData\Otopark\kayit\kopru-<şerit>.log`. Before this the installed
   bridge printed to a console nobody had, so the README's "watch the first
   day's logs" had no object.

3. **The server notices anyway.** The bridge pings every five minutes, and
   `run_kamera_kontrol` raises a Yönetici notification when the heartbeat goes
   stale — so a box that is off, unplugged or off the network surfaces as a
   push notification rather than as revenue that quietly stopped.

## Before you trust it

- **Keep THIS PC's clock right** (Windows: Settings → Time & language → *Set
  time automatically*). The bridge stamps the time the car was *seen* with the
  PC's clock — not the camera's — and the server bills from it. More than five
  minutes fast and every entry becomes a "future" exception instead of a
  ticket; slow, and every car is billed long. The installer checks it against
  the server (1.2.1) and the bridge logs `bilgisayarın saati sunucudan farklı`
  (at most hourly) when it drifts more than a minute.
- **Turn the camera on in the app**: Yönetim → Otopark ayarları → *Kamera girişi
  açık*. Until then the webhook refuses everything with 403.
- **Plate reading must be on too** (`plaka_saglayici` ≠ `KAPALI`) and the API
  key set. A photo arriving with reading switched off is refused with 409 —
  unlike the old build, this bridge has no local fallback.
- **Watch the first day's logs.** Every send and every refusal is printed.
- Cross-check `plaka_okuma_log` after a week: `onerilen` versus `kabul_edilen`
  is the real accuracy rate. Camera reads have no operator to confirm them, so
  this log is the only place a drift in accuracy will show up.
