# Kamera köprüsü

Watches an IP camera from a computer at the car park, **reads the plate on that
computer** and posts the plate text to `kamera-webhook`. **Nothing in this
folder is part of the web app** — it is not built, typechecked or deployed with
it. It runs on hardware you own.

The camera never touches the internet. It talks to this machine over the LAN;
this machine talks out. That is the whole security argument for the bridge.

## How it reads plates (1.3.0)

Owner decision, 2026-11-06. Up to 1.2.6 the bridge sent a photo and the server
read it with a cloud model, and a camera event (SMD, "vehicle") decided which
passes were cars. On site the photos were often taken at the wrong moment (the
plate cut at the crop's edge), reads failed, and tuning the camera's SMD / IVS
settings cost far more time than it saved. Both are gone:

- **Plate finder:** YOLOv9 (`yolo-v9-t-640`, open-image-models, ONNX). Code MIT;
  the weights' licence is not stated upstream — the owner accepted that risk.
  Not YOLOv8 / Ultralytics (AGPL-3.0).
- **Plate reader:** fast-plate-ocr `cct-s-v2-global` (ONNX, weights MIT). It won
  the bake-off: 97.5 % fully correct on 2,359 Turkish plates (RapidOCR 74.3 %).
- **Only sure reads are sent as plates.** Every plate box is read twice — tight
  and widened — and counts only if both texts agree and every character is at
  least 95 % likely; across frames the plate needs votes from two different
  views (one view is enough only at ≥ 99 %). Measured: **0 confident-wrong reads** on the public set and the site's
  photos. Anything less sure goes to staff with the photo ("Çözülmemiş
  kayıtlar"); there is no cloud read and no guess.
- **Grammar-constrained:** the reader may only produce a valid Turkish plate
  (province 01–81, the same pattern as the server's `vlm.ts`), and it never
  "fixes" an O into a 0 blindly — a forced character keeps its low probability
  and makes the read unsure.
- No per-read cost, no internet wait for reading, no camera menu to tune. About
  100–150 ms per frame on the site laptop's CPU.

The crop still carries the accuracy: the plate must be big enough in it. Since
1.3.0 the box can be drawn taller, with a **cut-out** over parked cars (see
*Kırpma sayfası*).

### Every car followed, gate area, crop as a clicked shape (1.4.0)

Up to 1.3.4 a decision was made per **pass**: any motion in the crop opened
one. On site (2026-11-08, noon) 13 plates were sent in 75 minutes but 17 staff
cards were opened, 4 of them in 13 s — every stop-and-go or parking move
inside the yard was a new pass. Worse, staff moving a parked plated car could
close its ticket as an exit (the single-gate server ignores repeats only for
3 min after entry).

Since 1.4.0 the bridge **follows each car** (`takip.py`): the vehicle finder's
boxes are matched frame to frame into a track; a plate box is written to the
car it sits in (lower part preferred, smallest box; two equal candidates → the
plate counts for nobody); every track has its own vote (`okuma.Gecis`), so the
plate safety rules are unchanged, only per car instead of per pass. One
decision per car (`okuma.iz_karari`); its time is the event's moment, never an
hours-old first read.

With a **gate area** (`KAPI_ALANI`, drawn on the crop page over the gate
approach, touching the picture edge):

- **In** — the car appeared in the gate area (came from outside) and drove out
  of it into the yard by more than a margin for 2 frames; decided when it stops
  (2 s), is lost, or at the latest 30 s later. Back into the gate first = U-turn,
  nothing sent.
- **Out** — the car came from the yard into the gate area and was lost THERE,
  while moving, heading to (or touching) the picture edge. A car that stood in
  the gate area and vanished behind a person is not "out" (park memory: it is
  the same car when it reappears).
- **Not seen in the gate (1.4.1)** — at ~3–4 frames/s a fast car can cross the
  gate area between two frames, and at night or in blur the finder may not see
  it there. A car first seen in the yard, moving away from the gate by at least
  the margin, whose position one frame earlier (its speed × the gap since the
  previous frame) was in the gate area (within the margin) counts as **in**; a
  car last seen in the yard, moving toward the gate, whose position one frame
  later was in the gate area counts as **out**. It looks back / ahead at most
  1.5 measured steps (after an idle spell the bridge measures only every 2 s).
  The log line says `(iz N, …, kapıda görülmedi)`.
- **Seen in only one frame (1.4.1)** — no speed, direction unknown. If it was
  in the gate area or within one car-box diagonal of it AND its pixels changed
  against the previous frame (it really moved), it becomes a staff card
  (`araç tek karede görüldü — personele`): any plate read goes as the guess; no
  plate → only if the vehicle score is ≥ `ARAC_GECIS_ESIK` (0.60), as for a
  plateless car rolling through. A one-frame box deep in the yard (the finder
  "blinking" on a parked car) is not sent; neither is one that overlaps
  another car's box in that frame (a car passing in front changes a parked
  car's pixels), nor the first frame after the camera comes back (compared
  with no stale picture). Car tracks only: a plate seen once is usually the
  front plate of a car whose body is found one frame later.
- **Plateless car through the gate (1.4.1)** — a tracked car that came in or
  went out through the gate area and whose plate was never read goes to staff
  from vehicle score **0.35** (the tracker's own birth threshold), not 0.60.
  Site log 2026-11-10: real cars at 0.46 / 0.54 were dropped silently; people
  scored at most 0.27 on the site photos. Other events (one-frame car, no gate
  area, car at the gate on start) keep 0.60. In practice every tracked car
  (tracks start at ≥ 0.35) that crosses the gate with no plate read becomes a
  staff card — more cards, never a ticket.
- **Plate read in several frames (1.4.1, `PLAKA_BIRLESIK`, default 1)** — the
  sure rule stays (two crops ≥ 95 % in two views, or 99 % once). In addition,
  a frame whose two crops read the SAME text with each ≥ 0.50 is a half vote;
  the text is sure when half + full votes come from ≥ 3 different views (a
  stopped car's frames are one view), one crop reached ≥ 0.90, no other text
  within one character was read anywhere in that car's track, and no OTHER
  plate has a vote, half vote or ≥ 0.50 guess in it (two cars mixed in one
  track must never bill the wrong one). Car tracks only — plate-only tracks
  (dark cars) keep the plain rule: their small box jitters into false views. Logged as
  `plaka birden çok karede aynı okundu (birleşik)`. Industry: Rekor plate
  groups, Axis update events; a frame-voting study: exact reads 66.7 → 81.8 %.
  On the 2026-11-10 staff-card photos the agreeing crops were always the right
  plate, and the one wrong read (55DAT642 beside 35DAT642) would block it.
  Tracking path only; `TAKIP=0` is unchanged.
- **Dark car, readable plate (1.4.1)** — a plate with no car box around it is
  followed on its own (as in 1.4.0). When the car's body becomes visible (a
  lamp in the yard), a NEWLY seen, undecided car track whose box holds that
  plate track takes it over — where it came from, whether it is already out of
  the gate, its reads. When the body goes dark again, the plate inside its
  expected box keeps the car track moving (box rebuilt from the plate). A car
  that was **stopped** when its body was last seen is never moved by a plate,
  so a dark car passing in front (even slowly) cannot drag a parked car's
  track to the gate. Known limit: a dark car that stops in the gate and then
  leaves still dark is not counted as out.
- **Moves inside the yard are not counted** (`otopark içinde hareket — sayılmadı`).
- A car already in the gate area when the bridge starts (or the camera comes
  back) that then drives in: we cannot know it came from outside → staff card.
- Lane: `GIRIS` sends only "in", `CIKIS` only "out", `ORTAK` both.

Without a gate area: a car that moved far enough is decided once when it stops
and once when it is lost while moving (each movement once); staff moves can
count, as before.

Measured on the 180 site photos before writing it: a parked car's box wobbles
on noise (IoU down to 0.845, anchor ~3 % of the diagonal), so "stopped" and
"new view" look at the car's **pixels** (the installer's `DURGUN_ESIGI`), the
box only cross-checks — a wobbling box must not count as a second view. A car
entering from the picture edge is found once about half of it is visible:
draw the gate area at least one car length deep. Plates with no car box
around them (2 of 18 on the photos) are followed on their own track, like
commercial plate cameras do.

Frames for the models: whenever a followed car or the gate area changed since
the models last looked, while any car moves or is missing, for 3 s after any
motion, and at least every 2 s. (The first version only watched whole-frame
motion; a parked car pulling away slowly changed too little per camera frame,
was never seen leaving, and its exit was lost — `test_kopru takip_ortulme`.)

A car hidden for a moment (a person walking past) keeps its track: a new box
continues an unmatched track within one car diagonal of its last position OR
of its speed-predicted position (up to 2 s ahead), within 4 s. That also keeps
one track on a busy laptop: checked with the scenarios at 0.25 / 0.4 / 0.5 s
model time per frame (site ≈ 0.15–0.25 s); before this fix, at 2 frames/s a
car jumped ~0.7 of its size per frame and every frame became a "new" car.

The **crop area** is now a clicked shape (≤ 8 corners, `KIRPMA_ALAN`): the
bridge crops its bounding rectangle and paints everything outside grey —
cut-outs are no longer needed. The plate edge rule becomes "the box plus its
margin is entirely inside the shape" (`plaka.AlanMaskesi`, integral image);
on rectangle and L-shaped areas it gives exactly the old answer
(`test_alan_maskesi_*`). Old `KIRPMA` + `KIRPMA_HARIC` keep working until the
crop is redrawn.

Fallback: `TAKIP=0`, a missing / broken vehicle finder or plate reader →
exactly 1.3.4 (all 39 old scenarios run with `TAKIP=0` and are unchanged).

### Plates read from the full-resolution crop (1.3.4)

`kopru.olcekle` shrinks the crop to `MAX_KENAR` (1568 px) before anything
looks at it. On site the crop is 2124 px wide → plates lost ~26 % of their
pixels, and square two-line plates (small top-row letters) stayed unsure:
night card "35CDJ06" — right guess, but "5"/"C" only 54–70 % sure. Since
1.3.4 the plate is still FOUND on the shrunk crop (the finder letterboxes to
640 anyway, and the edge / cut-out rule stays in those coordinates), but the
plate is CUT for reading from the full-resolution crop (cut-outs already
grey), the box scaled by the real shape ratio (`plaka.kutu_olcekle`). The
reader input is always 128×64, so the cost is one extra crop copy per job.
Evidence photos and the vehicle finder still use the shrunk crop. Safety
rules unchanged. Checked before release on the site photos: shrunk vs
full-res reads never disagreed when both were sure; one more plate became
sure (35KKM62, correct). `PLAKA_TAM=0` returns to 1.3.3; `--plaka` reads
every plate both ways and prints how many sure reads each gave.

### Plate reader and vehicle finder in parallel (1.3.3)

Up to 1.3.2 one worker read the plate and THEN ran YOLOX on each frame: on the
site laptop a frame cost ~410 ms (~2.4 frames/s), so a passing plate got only
3–4 chances, and the safety rule (2 sure views) was rarely met — cards like
"34MSN927 — plaka tam olarak okunamadı" although the guess was right. Since
1.3.3 `okuma.Isci` runs the two models in **separate threads, at the same
time**, each with its own queue: plate reading never waits for YOLOX (the
capture loop feeds a frame whenever the plate reader is free); YOLOX takes the
newest frame it can, and both still get the before-frame and the stopped frame
first (priority — now kept **in order**, up to 2, so a short pass cannot lose
the before-frame). The decision waits for both (`bekleme_suresi` uses the
slower one). On this PC: 1.6–1.8× more frames per second than one after the
other. `--plaka` prints both times and the expected frame rate.

### Vehicle finder (1.3.1)

On 1.3.0's first day (2026-11-07) two people standing still in front of the
camera became a "Çözülmemiş kayıt": 1.3.0's only model finds **plates**, and
"is it a car" was answered by how big the movement was. 1.3.1 adds a vehicle
finder that runs on **every frame**, after the plate work (owner decision —
no skipping: the plate finder once boxed something that was not a car).

- **Model:** YOLOX-tiny (Megvii, **Apache-2.0**), the official 0.1.1rc0 ONNX
  file, unchanged. COCO classes car / motorcycle / bus / truck count as a
  vehicle; person is logged only.
- **Bake-off on 180 real camera photos from this site:** real cars 0.40–0.94,
  people ≤ 0.27. YOLOX-nano was rejected — it missed close cars seen from
  above (0.01–0.12). ~55 ms per frame here on top of the plate finder (~84 ms);
  check the site laptop with `--plaka` (it prints ms per frame for both).
- **Input format matters and fails silently:** these files want raw BGR 0–255,
  top-left letterbox, pad 114. The older "legacy" format (RGB + ImageNet
  mean/std) found **zero** vehicles with no error. The start-up self-test
  (a real image must score 0.808 ± 0.05) and `test_arac` lock this.
- **Decisions** (see *When it sends*): a stopped plateless thing goes to staff
  only if a vehicle is seen; a rolling plateless **vehicle** now goes to staff
  too (1.3.0 dropped it silently). When the finder is missing, broken or off,
  every decision is exactly 1.3.0's — a car is never lost because of it.

**1.3.2 — only NEW vehicles count, and "new" is about WHERE.** On 1.3.1's
first evening two cars rolled through and nothing was recorded. The log
showed `araç durdu … gönderim yok` with vehicle 0.92–0.95: the frame
"before the pass" (the last frame that differed little from the one before
it) already held that same car, arriving slowly, so 1.3.0's departure rule
(a plate box in that frame) and 1.3.1's "a vehicle was already there" check
both said "nothing new" — and the empty lane afterwards did not match that
frame, so the pass even looked "stopped". Both checks also looked at the
whole picture, so a parked car in view would have blocked them too. Now the
finder returns boxes; a box counts only if it is not at the same place as a
box of the before-frame (IoU < 0.7 — a parked car overlaps itself ≥ 0.93
frame to frame, a car that moved 30 % of its length ~0.54). With the finder,
1.3.0's departure rule is not used (a sent car's departure is covered by the
disarm + `ayrilis`); an unsent car leaving the lane becomes a card — safe
direction. Every plateless decision logs what the before-frame held
(`önce: N araç, M plaka kutusu`).

Files: `plaka.py` (finder, reader, votes), `arac.py` (vehicle finder),
`okuma.py` (one decision per pass), `giden.py` (the outbox), models in
`modeller/` (licence and source: `modeller/LISANS.txt`, SHA-256 checked at
every start).

## What you need

- A Windows computer on the same network as the camera. An old laptop is the
  best choice available: it has a screen for diagnosis and the UPS is already
  inside it. The reader runs on the CPU (one thread); no GPU.
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
   1.2.2: kamera kökte (`/`) şifre istemiyorsa sınama marka yollarında sürer —
   her yolun ilk isteği şifresiz, şifre isteyen ilk yola tek kimlikli istek;
   yani bir yazım hatası yine tek başarısız giriş. Arama bilgisayarın HER
   ağından ayrı gönderilir (tek gönderimde Windows çoğu kez Wi-Fi'yi seçiyor,
   kablodaki kamera aramayı hiç duymuyordu); birden çok cihaz cevap verirse
   Enter hiçbirini seçmez.
3. **Kırpma kutusu** — tarayıcıda canlı görüntü açılır, şeridi kapsayan
   dikdörtgeni **fareyle sürüklersiniz** (sol/sağ kenar şeridin genişliği,
   üst kenar araçların durduğu yerin biraz üstü). Park etmiş araçlar kutuya
   giriyorsa **Hariç alan çiz** ile her birinin üstüne bir dikdörtgen (1.3.0;
   1.3.3'ten beri en çok 3, her biri ayrı silinir).
   Kutu 200 pikselin altına düşerse kırmızıya döner
4. **Test** — bağlantı ve gizli anahtar doğrulanır; 1.3.0'dan beri sunucunun
   "okunamadı" bildirimini tanıdığı da sınanır (eski `kamera-webhook` →
   durur, önce sunucuyu güncelleyin der); 1.2.1'den beri bu bilgisayarın
   saati de sunucununkiyle karşılaştırılır (bir dakikadan fazla fark = durur,
   ne yapılacağını söyler)

Kurulum, köprü başlayıp kameraya bağlandıktan **ve sunucu ilk kalp atışını
kabul ettikten** sonra "tamamlandı" der (1.2.1). Program `OtoparkKamera`
klasörünün kendisinden çalışıyorsa (ZIP'in klasörü, içinde yalnızca paket
dosyaları) o klasör yalnızca yöneticilerin değiştirebileceği hâle getirilir:
görev oradaki programı SYSTEM olarak çalıştırıyor. Başka bir klasörde (Masaüstü,
İndirilenler) izinlere DOKUNULMAZ, yalnızca uyarılır.

Yeniden kurulumda (1.2.2) o şeridin çalışan köprüsü, şerit belli olur olmaz —
kamera adımından ÖNCE — durdurulur; eskiden ancak 5. adımda duruyordu ve eski
şifreyle giriş denemeye devam edip sihirbazın şifre sınamasını kilide
sokuyordu. Kurulum yeni görevi kuramadan biterse (bırakıldı, Ctrl+C, hata,
görev oluşturulamadı) eskisi yeniden başlatılır. Öbür şeritlere dokunulmaz.

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
otopark. Köprü için hiçbir şey değişmez (okuduğu plakayı `yon: ORTAK` ile
gönderir); fark sunucudadır. Şerit yönü söyleyemediği için
`kamera-webhook` olayı `kamera_tek_kapi`'ye (037) verir ve karar **bilet
durumundan** çıkar:

| Plaka… | Karar |
|---|---|
| açık bileti var, bilet az önce açıldı (varsayılan 3 dk) | yok sayılır — araç hâlâ kameranın önünde |
| açık bileti var, daha eski | çıkış: yalnızca "kapıda" damgası |
| bileti az önce kapandı (varsayılan 5 dk) | yok sayılır — ödeyip çıkan araç |
| içerideki bir plakaya bir karakter uzak | Çözülmemiş kayıtlar (`YON_BELIRSIZ`) — tahmin edilmez |
| okunamadı (köprü emin değil: `okunamadi: true`, 1.3.0) | Çözülmemiş kayıtlar (`OKUNAMADI`, 039) — fotoğraflı, girdi mi çıktı mı bilinmez |
| hiçbiri | giriş: bilet açılır |

Cevap gövdesi `karar` ve `sebep` taşır ve köprü cevabı kayda yazdığı için her
karar `kopru-ortak.log` içinde okunabilir (`"karar":"YOKSAY","sebep":"YENI_GIRIS"`).

Şerit listesi tek yerde: `gunluk.SERITLER`. Kurulum, kaldırma ve köprü oradan
okur; `ORTAK` hiçbir yerde `GIRIS`e yuvarlanmaz. 1.0.0 kurulum programı
`ORTAK`ı tanımaz ve "şerit anlaşılmadı" diye durur — tek kapı için **1.1.0**
gerekir.

Giriş süresi 3 dakikanın altına indirilemez. Köprü bir aracı gönderdikten sonra
o araç gidene kadar susar; 1.3.0'da aynı plaka 60 sn içinde ikinci kez
gönderilmez ve gönderilmiş duran aracın **gidişi** tanınıp gönderilmez. Ama
kadrajda 60 sn'den uzun duran araç, önünde bir şey kıpırdayıp plakası yeniden
okunursa **yeniden gönderilir** — araç kaçırmamak için böyle. Tek kapıda o
ikinci gönderim, bilet 3 dakikadan eskiyse "çıkıyor" sayılır (para hareket
etmez, yalnızca "Kapıda" işareti). Kamerayı araçların **geçtiği** noktaya
çevirin; sıra beklenen ya da park edilen bir yeri hariç alanla dışarıda
bırakın.

Gönderim kutusu (1.3.0) yüzünden olaylar gecikerek de gelebilir. Tek kapı
kararları bu yüzden olayın **kendi saatine** göre verilir (048): 10:00 girişi
ile 10:30 çıkışı internet dönünce 11:00'de birlikte gelse de çıkış çıkıştır.

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

Yalnızca **prizdeyken** (AC) değerleri değişir; pil (DC) değerlerine bilerek
dokunulmaz (sahibin kararı). Pille çalışan dizüstü Windows varsayılanıyla
uyuyabilir ve elektrik gelince kendiliğinden uyanmaz — `OKU-BENI.txt` bunu
söyler.

Bağlantı testi bilerek **araç göndermez**: gerçek bir plaka gerçek bir bilet
açardı ve kurulum, kasada silinmesi gereken bir kayıt bırakmamalı. Sunucu
sürümü yoklaması da (`okunamadi` + `x-kamera-deneme`) hiçbir şey yazmaz.

Son adım "görev oluşturuldu" demekle yetinmez. Görev kurulup süreç kameraya
bağlanamadan ölebilir ve `schtasks` bunu **başarı** olarak bildirir; kurulumdan
çıkıp gitmiş birine bunu söyleyen hiçbir şey olmazdı.

### Çalışıyor mu?

`OtoparkKamera.exe`'ye tekrar çift tıklayın → **Durum**.

```
  ── GIRIS şeridi ──────────────────────────────
     Kamera       : rtsp://admin:•••@10.0.0.42:554/stream1
     Kırpma       : 31,613,2072,1100
     Hariç alan   : 31,613,500,300 (kesilen köşe)
     Otomatik başlatma: kurulu
     Son hareket  : 12 saniye önce
     Durum        : ÇALIŞIYOR
     Plaka okuma  : hazır
     Araç bulucu  : hazır
     Bugün        : 143 gönderim, 0 reddedilme, 6 personele, 21 plakasız hareket (araç görülmedi: 4)
```

`gönderim` sunucunun kabul ettiği her aracı sayar; `personele` onların
plakası emin okunamayıp fotoğrafıyla "Çözülmemiş kayıtlar"a düşenleridir.
`plakasız hareket` gönderilmeyen hareketlerdir (yaya, gölge, ışık — plaka hiç
görülmedi, araç da durmadı); kameranın görüntü verdiğinin kanıtı sayılır.
İnternet yokken bekleyen araç varsa `Bekleyen     : N araç (en eski …) —
internet gelince sırayla gönderilecek` satırı çıkar. 1.2.6'nın `Araç olayları`
ve `Boş şerit` satırları 1.3.0'da yok.

1.3.1: `Araç bulucu` satırı araç bulucunun hâlini söyler. `çalışmıyor` /
`kapalı` ise köprü 1.3.0 kuralıyla sürer (duran plakasız her şey personele) —
araç kaybolmaz, bu yüzden sağlık kırmızı **olmaz**, ama kameranın önünde duran
yaya yine kayıt açar. `araç görülmedi: N` = bugün duran ama araç olmadığı için
gönderilmeyen plakasız şeyler (insanlar); `plakasız hareket` sayısının içindedir.
Kayıtta sık sık `araç bulucu durulan kareye yetişmedi` görülürse dizüstü yavaştır.

Yedi koşulun **yedisi birden** aranır, çünkü her biri ötekinin kör noktasını
kapatıyor:

- **kamera görüntü veriyor mu** — kamerası olmayan köprü ölmez: açılışta
  kamerayı bekler, çalışırken yeniden bağlanır ve her denemede bir satır yazar,
  yani kayıt taze kalır. Durum ekranı `KAMERA YOK` der. Kamera köprünün
  şifresini reddediyorsa (1.2.2, `kamera şifreyi reddetti`) `KAMERA ŞİFRESİ
  REDDEDİLDİ` der ve "programı açıp Yeniden kur" der — sebep kablo değil

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
- **internet var mı** (1.2.4) — internet gidince köprü ve kamera çalışmaya ve
  kayıt yazmaya devam eder, yani tazelik ölçütü kesintiyi görmez; oysa o sırada
  geçen hiçbir araç sunucuya ulaşmaz. Son ağ sözü `kalp gönderilemedi` ya da
  `ağ hatası` ise durum ekranı `İNTERNET YOK` der. Köprü ağ hatasından sonraki
  ilk sunucu cevabında bir kez `internet bağlantısı geri geldi` yazar; o,
  başarılı bir gönderim, sunucunun herhangi bir cevabı ya da yeniden başlama
  kesintiyi bitirir. **1.3.0'dan beri kesinti sırasında görülen araçlar
  kaybolmaz:** her araç gönderilmeden ÖNCE gönderim kutusuna
  (`kayit\giden-<şerit>\`) yazılır ve sunucu kesin cevap verene kadar orada
  kalır, internet dönünce sırayla (en az 3 sn arayla) gider ve ancak o zaman
  silinir (`giden.py`). Bu, sahibin 2026-10-31 "çevrimdışı tampon yok"
  kararını **2026-11-06'da sahibin kendisi değiştirmesidir** — yalnızca
  kamera köprüsü için, yalnızca gönderilene kadar. Kamera yoksa önce `KAMERA
  YOK` söylenir.
- **plaka okuyucu çalışıyor mu** (1.3.0) — modeller açılamazsa köprü DÜŞMEZ:
  her araç-boyutlu geçiş fotoğrafıyla personele gider (araç kaybolmaz ama
  hepsi insana kalır). Durum ekranı `PLAKA OKUYUCU ÇALIŞMIYOR` der ve
  `Plaka okuma` satırı sebebi yazar.

Yanlış yönde yanılan bir sağlık göstergesi, göstergesizlikten kötüdür: kimse
bakmayı bırakmaz, herkes yanlış cevaba güvenir.

Köprü her yeniden bağlanmadan önce kameraya TEK bir şifre sınaması yapar
(1.2.2): her bağlanma bir giriştir ve eski sürüm şifresi değişmiş bir kamerayı
~3 sn'de bir deneyip Dahua hesabını kilitli tutuyordu. Sınama reddederse akış
hiç açılmaz ve `SIFRE_RED_BEKLEME_SN` (10 dk) beklenir — en çok 10 dakikada bir
başarısız giriş. Kalıcı durmaz: başkasının yol açtığı kilit de aynı cevabı
verir ve kilit bitince şerit kendiliğinden dönmeli. Başka her kopmada bekleme
3 sn'den 60 sn'ye katlanır, ilk iyi karede sıfırlanır.

### Kayıtlar

```
C:\ProgramData\Otopark\kayit\kopru-giris.log
```

Kurulan hâlinde köprüyü Görev Zamanlayıcı **SYSTEM** olarak başlatıyor ve o
sürecin konsolu yok — `print()` çıktısı hiçbir yere gitmiyordu. "İlk günün
kayıtlarını izleyin" tavsiyesinin karşılığı ancak bu dosyayla var.

2 MB'de döner, iki yedek tutulur (~6 MB tavan). Klasör yalnızca SYSTEM ve
yöneticilere açık. 1.3.0 kayda **plaka yazmaz** (kayıt yalnızca boyutla döner,
yani plaka orada süresiz kalırdı); araçlar `islem_id`'nin ilk sekiz hanesiyle
izlenir. Plaka ve fotoğraf yalnızca gönderim kutusunda (`kayit\giden-<şerit>\`)
durur, o da sunucu kabul edene kadar. 2000 aracı aşarsa `[!]` alarmı yazılır
ama yeni araçlar yine yazılır (asla sessizce düşmez). Bozuk bir dosya silinmez,
`.bozuk` olarak kenara ayrılır.

### Kaldırma

`OtoparkKamera.exe` → **Kaldır**. Görevi siler ve ayar dosyasını **gizli
anahtarıyla birlikte** kaldırır. Kayıtlar bilerek durur — arızayı anlamaya
çalışan kişinin elindeki tek iz; gönderim kutusunda bekleyen araç varsa o da
durur (`kayit\giden-<şerit>\`). Güç ayarları da durur; bilgisayarı başka bir
iş için kullanacaksanız Güç Seçenekleri'nden geri alın.

## Paketi üretmek (geliştirici)

Depo dışında bir venv'de (sürümler `requirements.txt` ile birebir olmalı):

```bash
python -m venv <venv>
<venv>\Scripts\python -m pip install -r requirements.txt pyinstaller pillow
<venv>\Scripts\python paketle.py
```

`dagitim/OtoparkKamera-<sürüm>-<tarih>.zip` (~85 MB) üretir ve SHA-256 özetini
yazar. Özeti dağıtımla birlikte verin: indirilen dosyanın yolda değişmediğini
doğrulamanın tek yolu.

1.3.0'dan beri `paketle.py` üç şeyi kendisi sınar ve tutmazsa durur:

- **Derlemeden önce:** `requirements.txt`'deki her sürüm kurulu olanla aynı mı
  (plaka okuyucunun altın çıktısı onnxruntime 1.31.0 ile ölçüldü) ve
  modellerin (1.3.1: araç modeli ve öz sınama resmi dâhil) SHA-256'sı
  `plaka.py` / `arac.py`'dekiyle aynı mı.
- **Derledikten sonra:** derlenen `.exe`'yi `--plaka-sina` ile GERÇEKTEN
  çalıştırır — modeller pakette mi, onnxruntime DLL'leriyle açılıyor mu, öz
  sınama geçiyor mu. Eksik bir DLL sahada değil burada görülür.
- **Lisanslar:** pakete giren her paketin lisans metni, derleme anında kurulu
  sürümden `lisanslar\` klasörüne toplanır (dizini `LISANSLAR.txt`); metni
  bulunamayan paket derlemeyi durdurur. Modellerin lisansı ve Python'unki de
  eklenir.

**onnxruntime telemetrisi:** resmî paket varsayılan olarak Microsoft'a
telemetri gönderir (paketin kendi `Privacy.md`'si). `plaka._ort_yukle` onu
ilk içe aktarmadan önce `ORT_DISABLE_TELEMETRY=1` ile ve ayrıca API ile kapatır;
onnxruntime'ı başka hiçbir yer içe aktarmaz (bir test bunu tutar).

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

Saves `kare.jpg` and prints the frame size. Open it, measure the lane's
rectangle and pass it as `x,y,w,h` in pixels: left and right edges at the
lane's width (no street), top edge a little above where cars stop. Frame it
**generously** — a plate touching the box's edge is treated as cut and is never
read; a box that only just fits will cut a tall van or a low sports car.

Parked cars inside the box? Add a **cut-out** over them, also `x,y,w,h` in
full-frame pixels. It must overlap the box and must not cover all of it; the
bridge paints it flat grey, so it brings no motion, no plate and no pixels into
the sent photo, and a plate touching its border counts as cut.

```bash
export KIRPMA="820,540,600,220"
export KIRPMA_HARIC="820,540,200,120"    # optional; up to 3: "a,b,c,d;e,f,g,h" (1.3.3)
python kopru.py --test
```

Saves `kirpik.jpg` (with the cut-out grey) — confirm the lane is actually inside
it — and then prints live `hareket` values. Watch them with the lane empty and
with a car pulling in: that tells you what to set `HAREKET_ESIGI` (moving) and
`DURGUN_ESIGI` (still) to, instead of guessing.

If `kirpik.jpg` comes back under 200 px on its long edge, the bridge warns you —
move the camera closer or zoom in; no reader recovers pixels that were never
captured. Then check real cars with `OtoparkKamera.exe --plaka` (as
administrator): it shows, live, every plate box, both reads, `EMİN` /
`belirsiz` / `kesik` and the milliseconds — and sends and saves nothing.

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
The models must be in `modeller/` next to `plaka.py` (they are in git and in
the package).

On Windows, `set` instead of `export`, and use Task Scheduler ("run whether user
is logged on or not") instead of the systemd unit below.

### When it sends (1.3.0)

The bridge works in **passes**. A pass starts at the first strong motion in the
crop while the lane is armed. The last still frame *before* the pass (the
background) is read first, with priority; then frames of the pass go to the
reader (a single slot, newest frame wins, so a slow read never piles up). The
reader runs in its own thread — the capture loop never waits for it.

A pass is **decided** when the car has stopped (the crop is still and does not
look like the background), when the scene goes back to the background (a car
that rolled through), after `GECIS_BEKLE_SN` without strong motion if the
scene never settles (rain, night grain), or when the stream drops. At the
decision the bridge waits for the reads in flight — at least `PLAKA_BEKLE_SN`
(0.4 s), and since 1.3.1 up to 2.5 × the worker's measured time per frame
(at most 2 s), so the stopped frame's vehicle score is in on a slow laptop
too — then:

| What was seen | What is sent |
|---|---|
| a **sure** plate (see *How it reads plates*) | the plate, with the photo of its best read; `zaman` = when it was **first** read |
| two different sure plates | both, in time order |
| plate boxes in ≥ 2 frames, nothing sure | `okunamadi` + the best guess and its confidence + photo → staff |
| a car-sized thing **stopped**, no plate box at all (and none in the background) — **without the vehicle finder** (missing / broken / off, or the before-frame was not measured) | `okunamadi` + photo → staff (1.3.0) |
| **with the finder (1.3.2):** car-sized, no plate, stopped, and the stopped frame shows a **new** vehicle ≥ `ARAC_BUL_ESIK` | `okunamadi` + photo → staff (`plakasız araç durdu`) |
| **with the finder:** car-sized, no plate, a **new** vehicle ≥ `ARAC_GECIS_ESIK` anywhere in the pass — stopped or not ("stopped" can be wrong when the car was already in the before-frame) | `okunamadi` + the frame where it was seen best → staff (`plakasız araç geçti`) |
| **with the finder:** stopped, but the stopped frame was not measured in time | `okunamadi` + photo → staff (`araç bulucu durulan kareye yetişmedi`) |
| **with the finder:** no new vehicle (people standing in front of the camera, shadows, a parked car) | nothing; the log says `hareket — plaka görülmedi … — araç görülmedi (araç 0.00, insan 0.91; önce: 1 araç, 0 plaka kutusu)` |
| motion, no plate, nothing stopped (people, shadows, light) | nothing; the log says `hareket — plaka görülmedi` |
| the departure of a stopped car that was sent | nothing (`gönderilmiş araç — tekrar gönderilmedi`) |
| the same plate (or one character away) sent in the last 60 s | nothing |
| the reader is down | every car-sized pass → `okunamadi` + photo → staff |

"Car-sized" means the crop changed from the background by at least
`ARAC_KAPSAM_ESIGI` during the pass; it is what keeps people walking past from
flooding staff. A departure is recognised when the pass starts from the sent
car's own picture, or when the sent plate is read in the pass's background
frame. "No plate in the background either" matters: when a plated car leaves
and the lane goes empty, the change is that car's departure, not something
that stopped (`kuyruk` holds it).

On the **exit lane** (`YON=CIKIS`) an unsure car is only logged
(`çıkış şeridinde okunamayan araç`): the server has no exception row for an
exit and the money there is in a person's hands anyway.

Every decision goes to the outbox first (`giden.py`), then a sender thread
posts it; the file is deleted only on a definitive answer (2xx, or a final
400/409, which is logged as `reddedildi`). 429, 5xx and network errors keep
it and retry with the **same** `islem_id` (1, 2, 4 … 60 s), and the outbox
wakes at once when the internet comes back. The server is replay-safe on
`islem_id`, so a crash between "accepted" and "deleted" only re-sends a no-op.
A server that does not know `okunamadi` (older `kamera-webhook`) answers 422
without an exception: the bridge logs `[!] sunucu okunamadı kaydını yazmadı`
and drops that one (the installer refuses such a server up front).

Motion blur is the weak point of a moving car: set a **fast fixed shutter**
(about 1/500 s) in the camera, and check a car after dark with `--plaka` —
infrared night pictures use a slower shutter and may need light at the gate.

After a send the lane is **disarmed until that vehicle leaves the frame** — the
crop has to stop matching the one that was sent. It is not a timer, and that
distinction is load-bearing: a fixed 60s cooldown used to outlive the 12s
motion window, so the *next* car settled while sending was blocked and was
already stale by the time it lifted. `MAX_BEKLEME_SN` forces a re-arm as
insurance; a repeat of the same car is stopped by the 60 s rule and, past it,
by the one-open-ticket-per-plate index on the server.

### The stored photo

Each car carries **one** photo: a compressed copy of the crop
(`foto_kanit_base64`) that the server stores as the ticket / exit / exception
photo (migration 042). Since 1.3.0 there is no reading copy (`foto_base64`):
nothing is read on the server. The copy is ≤ 1280 px and ≤ 100 KB (102,400
bytes — the same number as `KANIT_FOTO_EN_COK_BAYT` in
`supabase/functions/_shared/serit.ts`; a test keeps the two equal). JPEG
quality 80 → 40, then the picture shrinks by ×0.75, at most four rounds; if it
still does not fit the car goes **without** a photo, never without its record.
The cut-out is grey in it.

**No `KIRPMA` box → no photo** (owner decision, KVKK): without a box the crop is
the whole street view. The bridge says so once at startup.

### Tuning

All of these can be set in the lane's config file (`kopru-<şerit>.json`) or as
environment variables. A bad `PLAKA_*` / `ARAC_*` value never stops the bridge — the
default is used and a `[!]` line says so; the motion and timing values are
numbers that must be valid, or the bridge stops at start (and `durum` says so).

| Variable | Default | What it does |
|---|---|---|
| `KIRPMA` | *(none)* | `x,y,w,h` in pixels. Unset = the whole frame, which works but reads worse, and no photo is stored. |
| `KIRPMA_HARIC` | *(none)* | Cut-outs inside the box, `x,y,w,h` full-frame pixels, up to 3 separated by `;` (1.3.3): painted grey, no motion, no plate, not in the photo. A single rectangle is the same text as 1.3.0. |
| `KIRPMA_ALAN` | *(none)* | 1.4.0: the crop as a shape, `x,y;x,y;…` full-frame pixels, 3–8 corners, edges must not cross. Outside is painted grey. When set, `KIRPMA` / `KIRPMA_HARIC` are ignored (with a `[!]` line); a bad value stops the bridge like a bad `KIRPMA`. |
| `KAPI_ALANI` | *(none)* | 1.4.0: the gate area, same format. In / out are counted only through it; unset = no gate rule. A bad value or one not overlapping the crop → `[!]` and tracking without a gate rule (never stops). |
| `TAKIP` | `1` | 1.4.0: follow each car. `0` = 1.3.4 pass rules exactly. The installer never writes it, so a hand-set `0` survives a reinstall. |
| `MAX_KENAR` | `1568` | Long-edge cap of the crop before anything looks at it. Thresholds measured by the installer assume this. |
| `HAREKET_ESIGI` | `6.0` | Above this, something is moving. |
| `DURGUN_ESIGI` | `2.0` | Below this, the scene is still. |
| `DURGUN_KARE` | `5` | Still frames required before believing the car stopped. |
| `MIN_BEKLEME_SN` | `2` | Floor after a send before the lane can re-arm. Keep it well under a plausible dwell at the barrier. |
| `MAX_BEKLEME_SN` | `120` | Re-arm after this even if the scene never changed. Insurance — a wedged disarm would lose every later car. |
| `SAHNE_ESIGI` | `6.0` | How different the crop must look from the sent frame before the vehicle counts as gone. |
| `GECIS_BEKLE_SN` | `2` | Safety net: decide a pass after this long without strong motion, if the lane looks as it did before the pass. |
| `ARAC_KAPSAM_ESIGI` | `15` | How much the crop must change during a pass to count as car-sized. |
| `PLAKA_BUL` | `1` | `0` switches local reading off: every car-sized pass goes to staff. |
| `PLAKA_BUL_ESIK` | `0.30` | Plate finder score floor. |
| `PLAKA_OKU_ESIK` | `0.95` | Both crops' lowest character probability must reach this. |
| `PLAKA_TEK_ESIK` | `0.99` | A plate seen in only one view counts as sure only at this. |
| `PLAKA_IPLIK` | `2` | Threads for the plate reader and the vehicle finder. 1.3.2: on the site laptop (8 logical processors) a frame took 410 ms with 1, 268 ms with 2, 241 ms with 4 — 2 takes most of the gain and leaves cores for the camera stream. |
| `PLAKA_TAM` | `1` | 1.3.4: read the plate from the full-resolution crop (found on the shrunk one). `0` = 1.3.3. |
| `PLAKA_BIRLESIK` | `1` | 1.4.1: a plate read the same in ≥ 3 different views (both crops agree, each ≥ 0.50, one ≥ 0.90, no near-text in the track) is sure. `0` = only the single-frame 95 % rule. Tracking only. |
| `PLAKA_BEKLE_SN` | `0.4` | The least a decision waits for a read in flight (1.3.1: more on a slow laptop, see *When it sends*). |
| `ARAC_BUL` | `1` | `0` switches the vehicle finder (1.3.1) off: every decision is 1.3.0's. |
| `ARAC_BUL_ESIK` | `0.35` | A stopped plateless thing counts as a vehicle at this score. Bake-off: cars 0.40–0.94, people ≤ 0.27. |
| `ARAC_GECIS_ESIK` | `0.60` | A rolling plateless thing counts as a vehicle (→ staff) only at this score — shadows and car edges score up to ~0.55. |
| `YENIDEN_BAGLAN_SN` / `YENIDEN_BAGLAN_MAX_SN` | `3` / `60` | Wait before reconnecting after the stream drops; doubles up to the cap, back to the base on the first good frame (1.2.2). |
| `SIFRE_RED_BEKLEME_SN` | `600` | Wait after the camera rejects the stored password; the stream is not opened meanwhile (1.2.2). Keep it under 15 min, `durum`'s staleness limit. |

1.2.x settings that no longer do anything: `JPEG_KALITE`, `BOS_REFERANS`,
`BOS_ESIGI`, `BOS_OGREN`, `GECIS_YAKALA`, every `OLAY_*`, `ATLANAN_SAKLA`.
Left in an old config file they are simply ignored.

## Testler

```bash
python test_kopru.py            # yakalama döngüsü, 64 senaryo (39'u TAKIP=0, 25'i izleme)
python test_kopru.py iki_arac   # tek senaryo
python test_kurulum.py          # kurulum tarafı, 149 birim testi
python test_okuma.py            # kararlar + iki iş parçacığı + izleme karesi (okuma.py), 65 test
python test_plaka.py            # bulucu + okuyucu + oylama + çokgen alan (plaka.py), 48 test
python test_arac.py             # araç bulucu (arac.py), 16 test
python test_takip.py            # araç izleme, kapı kuralları (takip.py), 36 test
python test_giden.py            # gönderim kutusu (giden.py), 13 test
python test_mutasyon.py         # 82 kural tek tek bozulur; her biri yakalanmalı
```

`test_mutasyon.py` her kuralı (iki kırpıntı, kenar payı, oylama, 60 sn,
ayrılış, plakasız duran araç, bozuk okuyucu, kutudan silme, kayıtta plaka yok,
hariç alan, telemetri, eski sunucu, çıkış şeridi…) köprü klasörünün GEÇİCİ bir
kopyasında bozar ve onu tutan testin düştüğünü doğrular; önce her testin
bozulmamış kodda geçtiğini sınar. Depoya dokunmaz, hiçbir şey silmez.

`test_plaka.py`'nin iki testi ve `test_arac.py`'nin bir testi gerçek
modelleri çalıştırır ve yalnızca onnxruntime kuruluysa koşar (paket venv'i);
kurulu değilse "atlandı" der —
sürüm öncesi hepsi paket venv'inde de koşulmalı. 1.2.6'nın `olay.py` ve
`test_olay.py` dosyaları 1.3.0 ile kaldırıldı (kamera olayları kullanılmıyor).

Her çalıştırma bütün geçici dosyalarını `%TEMP%` altında TEK klasörde toplar
(`otopark-test-kurulum-…` / `-kopru-…` / `-giden-…` / `-plaka-…`) ve sonunda
yolunu yazar. Klasör silinmez; elle temizlenir. Hiçbir test bir şey silmez.

`test_kopru.py` gerçek `main()` döngüsünü sahte bir kamera, sahte bir ağ ve
sahte bir plaka okuyucuyla çalıştırır — karar mantığı (okuma.py, plaka.Oylama,
giden.py) taklit edilmez. Sahte plaka aracın altında işaret renginde
çizgilerdir; sahte okuyucu işareti bulur (bulanık karede bulamaz, gerçekte de
bulanık plaka okunmaz) ve numarasına göre plakayı okur. 1.3.1'den beri sahte
bir araç bulucu da var: açık gri gövde kırpıntının ne kadarını kaplıyorsa o
kadar "araç" der; koyu şekil (yaya, gölge) ve boş şerit 0 — gerçek model
test karelerindeki gri dikdörtgeni araç sanmazdı. `requests` kurulu
olmasa da koşar.

Bir zamanlar araç düşüren gerçek hatalardan gelenler: `iki_arac`, `429`,
`yavas`, `park`, `kuyruk` (sabit 60 sn'lik beklemenin olduğu sürümde dördü
kalıyordu); `gec_kamera` (elektrikten sonra bilgisayar kameradan önce açılır;
köprü kamerayı bekler ve beklerken kalp atışı GÖNDERMEZ); `kopma`;
`kalp_bloklamaz` (kalp atışı yakalamayı dondurmamalı); `sifre_degisti`,
`sifre_acilista`, `kopma_geri_cekilme` (kameranın hesabını kilitlememek,
1.2.2); `takilma` (bekçi, 1.2.4); `tek_kapi`; `kanit_fotografi` (kutuyla her
gönderim ≤ 100 KB geçerli JPEG; kutusuz hiçbir senaryoda fotoğraf yok);
`gecen_arac`, `gecen_iki_arac`, `gecen_gurultu`, `dokulu_zemin` (bariyersiz
kapı, 1.2.5/1.2.6); `duran_arac_degismez` (duran araç bir kez, gidişi hiç).

1.3.0'ın kuralları: `plakasiz_duran` (plakası görülmeyen duran araç
personele), `yaya_gecer` (plakasız, durmayan hareket hiçbir şey göndermez),
`anlasmazlik` (iki kırpıntı ayrı plaka → personele, tahminle), `kesik_plaka`
(kutunun kenarında kesik plaka hiç okunmaz → personele), `eski_sunucu`
(`okunamadi`yı tanımayan sunucu → `[!]`), `okuyucu_yok` (modeller yoksa köprü
düşmez, araç personele), `ag_yok_bekler` ve `internet_kesintisi` (kesintide
araçlar kutuda bekler, aynı `islem_id` ile ve SIRAYLA gider), `cikis_belirsiz`
(çıkışta okunamayan araç gönderilmez), `haric_alan` (hariç alanda duran araç
hiçbir şey üretmez), `ayni_plaka_60sn`. `kuyruk` 1.3.0'da yeni bir hatayı
yakaladı: plakalı araç gidip şerit boşalınca bu "plakasız bir şey durdu"
sanılıp personele yazılıyordu — artık geçişin arka plan karesi de okunuyor.

`test_okuma.py` kararları tek tek tutar: kesik plaka okunmaz, kesilen köşedeki
kutu düşer, iki kırpıntı kuralı, oylama, ayrılış, 60 sn, bozuk okuyucu,
kayıtta plaka yok. `test_plaka.py` ön işlemi ve kutu eşlemeyi yukarı akıştan
(open-image-models 0.5.1, fast-plate-ocr 1.1.0) ölçülmüş değerlere göre, Türk plaka kuralının
sunucununkiyle (`vlm.ts`) aynı metin olduğunu, model özetlerini, onnxruntime
telemetrisinin kapalı açıldığını ve gerçek okuyucunun sabit bir girdide sabit
çıktı verdiğini sınar. `test_giden.py` kutunun atomik yazımını, sırayı,
yalnızca kesin cevapta silmeyi, geçici hatada beklemeyi, dolu kutuda alarmı
(ama yazmayı) ve bozuk dosyanın silinmeyip ayrılmasını tutar.

`test_kurulum.py`'deki 142 birim testi kurulum tarafını tutuyor — ayar yükleme,
kayıt dosyası, durum ekranı, görev komutu, kırpma sayfası (hariç alan dâhil),
`--plaka` kipi, paket ön/son kontrolleri ve lisanslar. Orası bozulursa köprü
hiç **başlamaz** ve bunu kimse fark etmez: bariyerde sessizce duran bir süreç,
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

### Kendini toparlama (1.2.4)

Üç parça birlikte çalışır; biri olmadan öbürleri yetmez:

- **Çökme beklemez.** Beklenmeyen bir hata `giris.py`'de yakalanır, kayda yazılır
  ve süreç 1 ile çıkar. Eskiden paketlenmiş exe burada "Kapatmak için Enter'a
  basın" deyip bekliyordu — SYSTEM görevinde basacak kimse yok, süreç
  "çalışıyor" kalıyor, `IgnoreNew` yeni kopyayı engelliyordu. Çift tıklanan
  pencere beklemeye devam eder.
- **Dakikada bir yeniden başlatma.** Açılış tetiği dakikada bir, süresiz tekrar
  eder (`Repetition PT1M`). Köprü koşarken `IgnoreNew` tekrarı yok sayar;
  ölmüşse en geç bir dakikada başlar. `RestartOnFailure` tek başına yetmez:
  Görev Zamanlayıcı çalışmaya başlayıp sonra hata koduyla çıkan programı çoğu
  zaman "başarısız" saymaz ve 999 deneme sınırı vardır. Yan etki: ayar hatasıyla
  çıkan köprü dakikada bir yeniden dener ve her seferinde kayda yazar (kayıt
  boyutla döner).
- **Bekçi.** Yakalama döngüsü her karede canlılık damgası basar; uzun meşru
  beklemeler (`uyu`: yeniden bağlanma, 10 dk'lık şifre beklemesi, açılışta kamera
  beklemesi) dilim dilim basar. Damga `BEKCI_SN` (900 sn) boyunca hiç
  yenilenmezse — FFmpeg'in kendi ~30 sn'lik zaman aşımını da aşan ölü bir okuma,
  kilitlenme — bekçi `köprü takıldı` yazar ve `os._exit(3)` ile çıkar; tekrar
  tetiği yenisini başlatır. Bekçinin KENDİSİ zamanında uyanmadıysa bilgisayar
  uyumuştur: o zaman öldürmez, süreyi sıfırlar (`bekci_karari`, uykudan dönen
  sağlam köprü öldürülmez).

Uykudan dönüş (prizdeyken uyku kapalı; pil ya da elle uyutma): süreç uykudan
sağ çıkar, ölü okuma en geç FFmpeg zaman aşımında biter, yeniden bağlanma devreye
girer, kalp atışı en geç beş dakika içinde gider. Wi‑Fi gidip gelirse köprü
hiç durmaz; kalp atışı beş dakikalık sırasında kendiliğinden döner.

Kurulumun son adımı "köprü başladı" satırıyla yetinmez: köprü durmamış, kamerayı
açmış ve sunucu tarafından reddedilmemiş olmalı — Durum ekranıyla aynı ölçütler.
Değilse sihirbaz **"KURULUM TAMAMLANMADI"** der ve sebebi yazar.

## Kırpma sayfası

Yerel sayfa boş bir porta bağlanır (sabit 8099 doluysa sihirbaz çöküyordu),
`Host` başlığı yerel değilse hiçbir şey sunmaz ve `/kaydet` sayfaya gömülü
rastgele bir belirteç ister — aynı tarayıcıda açık başka bir site kırpma kutusunu
değiştiremez. Kare gelene kadar "Kameradan görüntü bekleniyor…" yazar; akış
koparsa yeniden bağlanır.

Reddedilen bir `/kaydet` isteğinin gövdesi 403'ten ÖNCE okunup atılır (1.2.2,
en çok 4096 bayt / 2 sn): Windows, okunmamış veri bekleyen soketi kapatırken
bağlantıyı sıfırlıyor ve istemci 403'ü okuyamadan "bağlantı kesildi"
alıyordu. Gerçek kullanımda yalnızca reddedilen istekler o yoldan geçer; testte
`test_kirpma_sunucusu_bos_port_ve_belirtec` bu yüzden ara sıra düşüyordu.

**Hariç alan (1.3.0; 1.3.3'ten beri en çok 3).** Kutu çizildikten sonra
**Hariç alan çiz**'e basıp kutunun içinde dikdörtgen çizilir (park etmiş
araçların üstü); kırmızı taralı ve numaralı görünür, kutunun dışına taşan
kısmı kesilir — görülen = kaydedilen. Üçüncüden sonra düğme kapanır. Her
alanın listede kendi **Hariç alanı sil** düğmesi vardır; **Tüm kareyi kullan**
hariç alan göndermez. Biri kutunun dışında kalan ya da kutunun tamamını
BİRLİKTE kaplayan alanlarla Kaydet kapalıdır (üst üste binenler iki kez
sayılmaz — sayfa, sunucu ve köprü aynı birleşim hesabını yapar); sunucu tarafı
(`_kutu_coz`) aynısını 400 ile reddeder ve köprünün kuralıyla
(`kopru.haric_metni_coz`) birebir aynıdır — 3000 rastgele kutu/liste ile
sınandı, sayfa gerçek tarayıcıda denendi. Gövde geriye uyumlu: `null` |
`{x,y,w,h}` | `{x,y,w,h,"haric":{x,y,w,h}}` | `{x,y,w,h,"haric":[{x,y,w,h}, …]}`.
**Neden 1.3.3:** plakası okunabilen park etmiş bir araç kadrajdaysa, başka bir
araç geçerken onun plakası da okunup gönderiliyordu (en çok dakikada bir) —
tek kapıda park etmiş araca bilet açar ya da kapatırdı (`test_kopru
ikinci_haric_park_plakali`). Sihirbaz `KIRPMA_HARIC`'i HER ZAMAN yazar (yoksa
`""`): yeniden kurulumda eski hariç alan yeni kutuya geri dönmesin.

**Kırpma alanı ve kapı alanı (1.4.0).** Sayfa artık dikdörtgen değil
**köşe köşe tıklanan** alan çizer (en çok 8; ilk köşeye yeniden tıklamak
alanı kapatır; **Son köşeyi sil**, **Alanı sil**). İki mod: **Kırpma alanı**
(izlenecek yer; park etmiş araçları DIŞARIDA bırakın — dışı karartılır, köprü
orayı griye boyar) ve **Kapı alanı** (kapının önü, araçların girip çıktığı
yer; resmin kenarına kadar, en az bir araç boyu derin, araçların park
etmediği bir yer). Karenin kenarına %3'ten yakın kırpma köşesi kenara, kapı
köşesi kırpmanın çevreleyen dikdörtgenine yapışır: kenardan giren aracın
alttan kesik kutusu alanın içinde kalsın. Kapı alanı kırpmanın dışına
taşabilir ama onunla hiç kesişmiyorsa kaydedilmez. Kurallar sunucuda
(`_alan_coz` → `plaka.cokgen_coz`, köprüyle aynı) esastır; sayfanın
yapıştırması ve denetimi aynı hesabın görüntüsüdür. Gövde: `{"alan":
[[x,y],…]|null, "kapi": [[x,y],…]|null}`; eski `{x,y,w,h,haric}` gövdesi
hâlâ kabul edilir. Sihirbaz `KIRPMA_ALAN` ve `KAPI_ALANI`'nı HER ZAMAN yazar
(yoksa `""`), alan çizildiyse `KIRPMA` / `KIRPMA_HARIC`'i boşaltır; `TAKIP`'e
dokunmaz. Sayfa gerçek tarayıcıda sahadaki görüntüyle denendi (köşe tıklama,
yapışma, son köşeyi sil, kaydet → sunucu iki alanı da sakladı).

Eşikler **seçilen kutunun içinde** ölçülür (hariç alan griye boyanmış olarak): köprü hareketi kırpılmış görüntüde
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
- **Deploy `kamera-webhook` first.** 1.3.0 needs the webhook that knows
  `okunamadi` (an older one would drop every unsure car); the installer checks
  and stops otherwise. The server's plate-reading setting (`plaka_saglayici`)
  no longer matters for the camera — it only drives the phone's OCR.
- **Run `--plaka` on installation day,** with cars, in daylight **and** after
  dark: every car should show `EMİN` with its correct plate at least once.
- **Watch the first days.** `durum`'s `personele` and `plakasız hareket`
  counts, and every camera ticket's plate against the car. Camera reads have
  no operator to confirm them, so this is where a drift in accuracy shows up.
  A wrong sure read is the one failure the design aims at zero; report any.
- **Rollback** is the released 1.2.6 package: the webhook change is additive,
  so 1.2.6 works against the new server unchanged — but it reads in the cloud
  again, so leave the server's plate reading and API key in place until 1.3.0
  has proven itself.
