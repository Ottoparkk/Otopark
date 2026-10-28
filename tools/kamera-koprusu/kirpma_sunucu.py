# -*- coding: utf-8 -*-
"""
Tarayıcıda canlı kare üstünde kırpma kutusu seçtiren küçük yerel sunucu.

Kurulumun en zor adımı buydu: `--kare` ile bir JPEG kaydedip onu bir resim
düzenleyicide açıp plakanın dikdörtgenini piksel piksel ölçmek ve
KIRPMA="820,540,600,220" diye yazmak. Teknik olmayan biri orada duruyordu.

Aynı sayfa hareket değerlerini de canlı gösterir, böylece HAREKET_ESIGI ve
DURGUN_ESIGI tahmin edilmek yerine ÖLÇÜLÜR.

Yalnızca 127.0.0.1'e bağlanır: güvenlik duvarı sormaz, ağa açılmaz.
"""
from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np

SAYFA = """<!doctype html>
<html lang="tr"><head><meta charset="utf-8">
<title>Otopark — Kırpma Kutusu</title>
<style>
 :root{color-scheme:dark}
 body{margin:0;background:#14161a;color:#ececec;
      font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
 .sar{max-width:900px;margin:0 auto;padding:24px}
 h1{font-size:20px;margin:0 0 4px}
 p.alt{margin:0 0 20px;color:#9aa0a8}
 .tuval{position:relative;display:inline-block;line-height:0;
        border-radius:12px;overflow:hidden;background:#000}
 canvas{max-width:100%;height:auto;cursor:crosshair;display:block}
 .kutu{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0}
 .kart{flex:1;min-width:180px;background:#1c1f24;border:1px solid #2a2f36;
       border-radius:12px;padding:12px 14px}
 .kart b{display:block;font-size:12px;color:#9aa0a8;font-weight:600;
         letter-spacing:.04em;text-transform:uppercase;margin-bottom:4px}
 .kart span{font-size:22px;font-variant-numeric:tabular-nums}
 .iyi{color:#4ade80}.kotu{color:#f87171}
 button{font:inherit;font-weight:600;border:0;border-radius:10px;
        padding:12px 20px;cursor:pointer}
 .bas{background:#5ecfe8;color:#0f1013}
 .bas:disabled{opacity:.4;cursor:not-allowed}
 .ikinci{background:#2a2f36;color:#ececec;margin-left:8px}
 .ipuc{background:#1c1f24;border-left:3px solid #5ecfe8;border-radius:8px;
       padding:12px 14px;margin:16px 0;color:#c9ced6;font-size:14px}
</style></head><body><div class="sar">
<h1>Kırpma kutusunu seçin</h1>
<p class="alt">Bir araç bariyerde dururken, plakanın bulunduğu dikdörtgeni
fareyle sürükleyin. Bol tutun — kutu plakanın kenarlarına yapışmasın.</p>

<div class="ipuc" id="bekle">Kameradan görüntü bekleniyor… Birkaç saniye içinde
gelmezse kameranın açık ve bu bilgisayarla aynı ağda olduğunu kontrol edin.</div>
<div class="tuval"><canvas id="t"></canvas></div>

<div class="kutu">
  <div class="kart"><b>Kırpma</b><span id="olcu">—</span></div>
  <div class="kart"><b>Okunabilirlik</b><span id="kalite">—</span></div>
  <div class="kart"><b>Hareket (canlı)</b><span id="hareket">—</span></div>
</div>

<div class="ipuc" id="ipuc">Kutuyu çizin. Uzun kenarı <b>200 pikselin</b>
altında kalırsa plaka güvenilir okunmaz — kamerayı yaklaştırın ya da zoom
yapın.</div>

<button class="bas" id="kaydet" disabled>Kaydet ve devam et</button>
<button class="ikinci" id="tumu">Tüm kareyi kullan</button>
</div><script>
const t=document.getElementById('t'),c=t.getContext('2d');
let img=new Image(),kutu=null,ciz=false,bas=null,olcek=1,kaynak=[0,0];

function boya(){
  if(!img.width)return;
  t.width=img.width;t.height=img.height;kaynak=[img.width,img.height];
  c.drawImage(img,0,0);
  if(kutu){
    c.strokeStyle='#5ecfe8';c.lineWidth=Math.max(2,img.width/400);
    c.setLineDash([]);c.strokeRect(kutu.x,kutu.y,kutu.w,kutu.h);
    c.fillStyle='rgba(94,207,232,.15)';c.fillRect(kutu.x,kutu.y,kutu.w,kutu.h);
  }
}
function yenile(){
  const y=new Image();
  // Kare gelene kadar siyah, açıklamasız bir kutu görünüyordu; kamera hiç
  // cevap vermezse kullanıcı neyi beklediğini bilmiyordu.
  const b=document.getElementById('bekle');
  y.onload=()=>{img=y;boya();if(b)b.style.display='none';};
  y.onerror=()=>{if(b&&!img.width)b.style.display='';};
  y.src='/kare.jpg?t='+Date.now();
}
// Ekrandaki tuval CSS ile küçülüyor; fare koordinatını KAYNAK piksele çevir,
// yoksa kaydedilen kutu görülenden başka bir yeri gösterir.
function nokta(e){
  const r=t.getBoundingClientRect();
  return {x:Math.round((e.clientX-r.left)*(t.width/r.width)),
          y:Math.round((e.clientY-r.top)*(t.height/r.height))};
}
t.addEventListener('pointerdown',e=>{ciz=true;bas=nokta(e);t.setPointerCapture(e.pointerId);});
t.addEventListener('pointermove',e=>{
  if(!ciz)return;const p=nokta(e);
  kutu={x:Math.min(bas.x,p.x),y:Math.min(bas.y,p.y),
        w:Math.abs(p.x-bas.x),h:Math.abs(p.y-bas.y)};
  boya();guncelle();
});
t.addEventListener('pointerup',()=>{ciz=false;});
function guncelle(){
  const o=document.getElementById('olcu'),k=document.getElementById('kalite'),
        b=document.getElementById('kaydet');
  if(!kutu||kutu.w<8||kutu.h<8){o.textContent='—';k.textContent='—';b.disabled=true;return;}
  o.textContent=kutu.w+'×'+kutu.h+' px';
  const uzun=Math.max(kutu.w,kutu.h),iyi=uzun>=200;
  k.textContent=iyi?'Yeterli':'Çok küçük';
  k.className=iyi?'iyi':'kotu';
  b.disabled=false;
}
document.getElementById('kaydet').onclick=()=>gonder(kutu);
document.getElementById('tumu').onclick=()=>gonder(null);
function gonder(k){
  // Kutu KARENİN içine sıkıştırılır: fare tuvalin dışına sürüklenince
  // koordinatlar eksiye ya da karenin ötesine taşabiliyor.
  if(k){
    const x=Math.max(0,Math.min(k.x,kaynak[0]-1)),y=Math.max(0,Math.min(k.y,kaynak[1]-1));
    k={x:x,y:y,w:Math.max(1,Math.min(k.x+k.w,kaynak[0])-x),
       h:Math.max(1,Math.min(k.y+k.h,kaynak[1])-y)};
  }
  fetch('/kaydet',{method:'POST',
    headers:{'Content-Type':'application/json','X-Otopark-Belirtec':'__BELIRTEC__'},
    body:JSON.stringify(k)}).then(r=>{
      // Reddedilen bir kayıt "Kaydedildi" DEMEMELİ: sihirbaz hâlâ bekliyor.
      if(!r.ok){
        document.getElementById('ipuc').textContent=
          'Kaydedilemedi. Sayfayı yenileyip kutuyu tekrar çizin.';
        return;
      }
      // Sunucu kaydettikten hemen sonra kapanıyor. Zamanlayıcılar durdurulmazsa
      // kapanmış porta saniyede iki istek atmaya devam edip konsolu hata
      // akışıyla dolduruyorlar — kaydetme çalışsa bile bitmemiş görünüyor.
      zamanlayicilar.forEach(clearInterval);
      document.body.innerHTML='<div class="sar"><h1>Kaydedildi</h1>'+
        '<p class="alt">Bu sekmeyi kapatabilirsiniz — kuruluma dönün.</p></div>';
    });
}
const zamanlayicilar=[
  setInterval(yenile,1000),
  // Öğe kontrolü ve .catch: kapanma ile son isteğin dönüşü arasında sayfa
  // zaten değişmiş olabiliyor.
  setInterval(()=>fetch('/olcum').then(r=>r.json()).then(d=>{
    const h=document.getElementById('hareket');
    if(h)h.textContent=d.hareket.toFixed(2);
  }).catch(()=>{}),500),
];
yenile();
</script></body></html>"""


BELIRTEC_BASLIGI = "X-Otopark-Belirtec"

# /kaydet gövdesinin üst sınırı. Bir kutu en çok birkaç on bayttır; sınırsız
# okuma yok — reddedilen isteğin gövdesi de en çok bu kadar okunup atılır.
GOVDE_EN_COK = 4096
# Reddedilen isteğin gövdesini beklemenin üst sınırı (sn): gövdeyi hiç
# göndermeyen bir istemci bir iş parçacığını sonsuza dek tutmasın.
GOVDE_BEKLEME_SN = 2.0

# Kutu kaydedildikten sonra KIRPMA üzerinde hareket ölçülen süre.
KIRPIK_OLCUM_SN = 6.0

# Art arda bu kadar başarısız okumadan sonra akış kapatılıp yeniden açılır.
YENIDEN_BAGLAN_SAYISI = 6


class _Durum:
    """Kameradan gelen en son kare ve hareket ölçümleri."""

    def __init__(self) -> None:
        self.kare: np.ndarray | None = None
        self.hareket = 0.0
        self.hareketler: list[float] = []          # tüm kare
        self.kirpik_hareketler: list[float] = []   # yalnızca seçilen kutu
        self.kutu: tuple[int, int, int, int] | None = None
        self._onceki: np.ndarray | None = None
        self._onceki_kirpik: np.ndarray | None = None
        self.kilit = threading.Lock()
        self.dur = False

    def olcum_ekle(self, kare: np.ndarray) -> None:
        """
        Bir kareyi işler: sayfanın gösterdiği tüm-kare hareketi ve — kutu
        seçildiyse — KIRPMA üzerindeki hareket.

        İkincisi asıl olan. Köprü hareketi kırpılmış görüntüde ölçer
        (kopru.main: gri_kucuk(olcekle(kirp(...)))); eşikler tüm kareden
        çıkarılırsa başka bir sinyalden çıkarılmış olur: kutunun dışındaki
        hareket eşiğe girer, içindeki ise bütün kareye yayılıp küçülür.
        Aynı üç yardımcı kullanılıyor ki iki taraf ayrışamasın.
        """
        # Geç içe aktarma: kopru modülün tamamını (dolayısıyla `requests`'i)
        # gerektiriyor; kırpma sayfası onsuz da içe aktarılabilmeli.
        from kopru import fark, gri_kucuk, kirp, olcekle

        g = gri_kucuk(kare)
        h = fark(self._onceki, g)
        with self.kilit:
            kutu = self.kutu
        kg = gri_kucuk(olcekle(kirp(kare, kutu))) if kutu else None
        kh = fark(self._onceki_kirpik, kg) if kutu else None
        self._onceki, self._onceki_kirpik = g, kg
        with self.kilit:
            self.kare = kare
            self.hareket = h
            self.hareketler.append(h)
            if len(self.hareketler) > 2000:
                del self.hareketler[:1000]
            if kh is not None:
                self.kirpik_hareketler.append(kh)


def esik_secimi(kutu, tum_kare: list[float], kirpik: list[float]) -> list[float]:
    """Eşik önerisine girecek seri: kutu varsa kırpma ölçümü, yoksa tüm kare."""
    return kirpik if kutu else tum_kare


def _kamera(rtsp: str):
    """
    Köprünün KENDİ bağlantı yolu: RTSP üzerinden TCP ve tek karelik tampon.

    Eskiden burada ayrı bir VideoCapture kuruluyordu. Kamera taraması TCP
    seçeneğini geri almış ve kopru henüz içe aktarılmamış oluyordu, yani bu
    sayfa UDP ile bağlanıyordu: Windows Güvenlik Duvarı yeni programın gelen
    UDP paketlerini engellerse sayfa "görüntü bekleniyor"da kalıyordu, oysa
    tarama da köprü de (ikisi TCP) çalışıyordu. Geç içe aktarma, olcum_ekle
    ile aynı sebeple.
    """
    from kopru import kamera_baglan
    return kamera_baglan(rtsp)


def _okuyucu(rtsp: str, d: _Durum) -> None:
    cap = _kamera(rtsp)
    bos = 0
    while not d.dur:
        ok, kare = cap.read()
        if not ok or kare is None:
            # Aynı nesnede sonsuza dek okumayı denemek, kopmuş bir akışta
            # sayfayı sonsuza dek siyah bırakıyordu. Birkaç boş okumadan sonra
            # akış kapatılıp yeniden açılır.
            bos += 1
            if bos >= YENIDEN_BAGLAN_SAYISI:
                cap.release()
                cap = _kamera(rtsp)
                bos = 0
            time.sleep(0.5)
            continue
        bos = 0
        try:
            d.olcum_ekle(kare)
        except Exception:
            # Tek bir bozuk kare okuyucuyu öldürmemeli.
            pass
        time.sleep(0.04)
    cap.release()


def _kutu_coz(veri) -> tuple[bool, tuple[int, int, int, int] | None]:
    """
    /kaydet gövdesi: `null` = tüm kare, ya da {x, y, w, h}. (geçerli mi, kutu)

    Dört değer de GERÇEK tamsayı olmalı (bool ve kesir değil), konum negatif
    olamaz, boyut pozitif olmalı. Kutu ayar dosyasına ve oradan köprüye
    gidiyor; orada patlayacak bir değeri burada reddetmek, kurulum bittikten
    sonra başlamayan bir köprüden iyidir.
    """
    if veri is None:
        return True, None
    if not isinstance(veri, dict):
        return False, None
    try:
        x, y, w, h = (veri[k] for k in ("x", "y", "w", "h"))
    except KeyError:
        return False, None
    for v in (x, y, w, h):
        if isinstance(v, bool) or not isinstance(v, int):
            return False, None
    if x < 0 or y < 0 or w <= 0 or h <= 0:
        return False, None
    return True, (x, y, w, h)


def sunucu_baslat(d: _Durum, port: int = 0):
    """
    Yerel sayfayı sunan sunucuyu kurar (başlatmaz). Döndürür:
    (sunucu, sonuc, bitti, belirtec).

    `port=0`: boş bir portu işletim sistemi seçer. Sabit 8099 doluysa (başka
    bir program, ya da yarıda kalmış önceki sihirbaz) kurulum, kamera
    eşleştirildikten SONRA bir yığın iziyle çöküyordu.

    Sayfa yalnızca bu bilgisayardan açılır ama aynı tarayıcıdaki başka bir
    site de 127.0.0.1'e istek atabilir. Üç ayrı kilit:
      · Host başlığı yerel değilse hiçbir şey sunulmaz (DNS rebinding).
      · /kaydet, sayfaya gömülü rastgele belirteci özel bir başlıkta ister.
        Özel başlık, başka kökenden gelen isteği tarayıcıda ön-denetime
        (OPTIONS) düşürür ve o burada hiç cevaplanmaz.
      · Origin başlığı varsa bizim adresimiz olmalı.
    """
    import hmac
    import secrets

    belirtec = secrets.token_urlsafe(32)
    sonuc: dict = {}
    bitti = threading.Event()
    sayfa = SAYFA.replace("__BELIRTEC__", belirtec).encode("utf-8")

    class Isleyici(BaseHTTPRequestHandler):
        def log_message(self, *a):      # konsolu istek günlüğüyle doldurma
            pass

        def _yaz(self, kod, tur, govde: bytes):
            self.send_response(kod)
            self.send_header("Content-Type", tur)
            self.send_header("Content-Length", str(len(govde)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(govde)

        def _yerel_mi(self) -> bool:
            p = self.server.server_address[1]
            return self.headers.get("Host", "") in (f"127.0.0.1:{p}", f"localhost:{p}")

        def _red(self):
            self._yaz(403, "text/plain; charset=utf-8", "reddedildi".encode())

        def _govdeyi_at(self) -> None:
            """
            Reddedilecek bir POST'un gövdesini okuyup atar (1.2.2).

            403 gövde okunmadan yazılıp bağlantı kapanınca Windows, okunmamış
            veri bekleyen soketi SIFIRLIYORDU (RST) ve istemci 403'ü okuyamadan
            "bağlantı kesildi" alıyordu. Gövde GOVDE_EN_COK'u aşıyorsa ya da
            GOVDE_BEKLEME_SN içinde gelmezse okunmaz — reddin kendisi değişmez.
            """
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return
            if not 0 < n <= GOVDE_EN_COK:
                return
            try:
                self.connection.settimeout(GOVDE_BEKLEME_SN)
                self.rfile.read(n)
            except OSError:
                pass

        def do_GET(self):
            if not self._yerel_mi():
                self._red()
                return
            if self.path.startswith("/kare.jpg"):
                with d.kilit:
                    kare = None if d.kare is None else d.kare.copy()
                if kare is None:
                    self._yaz(503, "text/plain; charset=utf-8", "kare yok".encode())
                    return
                ok, buf = cv2.imencode(".jpg", kare, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
                if not ok:
                    self._yaz(503, "text/plain; charset=utf-8", "kare yok".encode())
                    return
                self._yaz(200, "image/jpeg", buf.tobytes())
            elif self.path.startswith("/olcum"):
                with d.kilit:
                    h = d.hareket
                self._yaz(200, "application/json",
                          json.dumps({"hareket": h}).encode())
            else:
                self._yaz(200, "text/html; charset=utf-8", sayfa)

        def do_POST(self):
            p = self.server.server_address[1]
            koken = self.headers.get("Origin")
            if (not self._yerel_mi()
                    or not self.path.startswith("/kaydet")
                    or (koken is not None and koken not in (
                        f"http://127.0.0.1:{p}", f"http://localhost:{p}"))
                    or not hmac.compare_digest(
                        self.headers.get(BELIRTEC_BASLIGI, ""), belirtec)):
                self._govdeyi_at()
                self._red()
                return
            try:
                n = int(self.headers.get("Content-Length", "0"))
                if n < 0 or n > GOVDE_EN_COK:
                    raise ValueError("gövde boyutu")
                veri = json.loads(self.rfile.read(n) or b"null")
            except Exception:
                self._yaz(400, "application/json", b'{"hata":"govde"}')
                return
            gecerli, kutu = _kutu_coz(veri)
            if not gecerli:
                self._yaz(400, "application/json", b'{"hata":"kutu"}')
                return
            # Sonuç, cevap yazılmadan ÖNCE işaretlenir: sunucu iş parçacıklı,
            # ve tarayıcı cevabı aldığı anda sihirbazın da bunu görmüş olması
            # gerekir. kirpma_sec kapatmadan önce kısa bir süre bekliyor, yani
            # bu cevap yine de gider.
            sonuc["kutu"] = kutu
            bitti.set()
            self._yaz(200, "application/json", b'{"ok":true}')

    # İş parçacıklı: tarayıcılar sayfanın adresine yedek, BOŞ bağlantılar
    # açar. Tek iş parçacıklı sunucu onlardan birini okurken takılıyor ve
    # saniyede bir gelen kare/hareket istekleri o soket kapanana kadar
    # bekliyordu — sayfa donmuş görünüyordu.
    sunucu = ThreadingHTTPServer(("127.0.0.1", port), Isleyici)
    sunucu.daemon_threads = True
    return sunucu, sonuc, bitti, belirtec


def kirpma_sec(rtsp: str, port: int = 0) -> tuple[tuple[int, int, int, int] | None,
                                                  list[float]]:
    """
    Tarayıcıyı açar, kullanıcı kutuyu çizene kadar bekler.

    Döndürür: (kutu ya da None, eşik önerisi için hareket değerleri).
    None = "tüm kareyi kullan". Kutu seçildiyse hareket değerleri o KUTUNUN
    içinden ölçülür (bkz. _Durum.olcum_ekle).
    """
    d = _Durum()
    threading.Thread(target=_okuyucu, args=(rtsp, d), daemon=True).start()

    sunucu, sonuc, bitti, _ = sunucu_baslat(d, port)
    threading.Thread(target=sunucu.serve_forever, daemon=True).start()

    adres = f"http://127.0.0.1:{sunucu.server_address[1]}/"
    print(f"\n  Tarayıcıda açın:  {adres}", flush=True)
    try:
        import webbrowser
        webbrowser.open(adres)
    except Exception:
        pass
    print("  Kutuyu çizip 'Kaydet' deyin; burada bekleniyor…", flush=True)

    bitti.wait()
    time.sleep(0.3)               # tarayıcı cevabı alsın
    sunucu.shutdown()
    sunucu.server_close()

    kutu = sonuc.get("kutu")
    if kutu:
        # Kutu ancak şimdi biliniyor. Birkaç saniye daha izlenip hareket bu
        # kez kutunun içinde ölçülür; eşikler bundan çıkar.
        print("  Seçilen kutuda hareket ölçülüyor…", flush=True)
        with d.kilit:
            d.kutu = kutu
        time.sleep(KIRPIK_OLCUM_SN)
    d.dur = True
    with d.kilit:
        olcumler = esik_secimi(kutu, list(d.hareketler), list(d.kirpik_hareketler))
    return kutu, olcumler


def esik_oner(olcumler: list[float]) -> tuple[float, float]:
    """
    Gözlenen hareket değerlerinden DURGUN_ESIGI ve HAREKET_ESIGI önerir.

    Sahnenin çoğu zaman durgun olduğu varsayımıyla: alt yüzdelikler gürültü
    tabanı, üstü gerçek hareket. Yeterli veri yoksa kopru.py'nin varsayılanları
    döner — kötü bir öneri, tahmin edilmiş bir eşikten daha tehlikelidir.
    """
    if len(olcumler) < 50:
        return 2.0, 6.0
    s = sorted(olcumler)
    taban = s[int(len(s) * 0.60)]          # sessiz anların üst sınırı
    tepe = s[int(len(s) * 0.99)]
    # Seride gerçek bir hareket YOKSA (tepe gürültü tabanından ayrışmıyor)
    # hareketin ölçeği bilinmiyor demektir. Kutu kaydedildikten sonraki kısa
    # ölçüm çoğu zaman böyledir: şerit boş ya da araç duruyor. O durumda
    # aşağıdaki formül hareket eşiğini gürültünün hemen üstüne koyardı ve
    # şerit bir daha hiç "durgun" görünmezdi. Varsayılanlar korunur; yalnızca
    # gürültü tabanı onları aşıyorsa yukarı çekilir.
    if tepe < max(3.0, taban * 3):
        durgun = max(2.0, round(taban * 1.5, 1))
        return durgun, max(6.0, round(durgun * 3, 1))
    # Hareket görülmüş olsa da eşikler varsayılanın (2.0 / 6.0) ALTINA İNMEZ,
    # yalnızca yukarı çekilebilir. Ölçüm gündüz, altı saniyelik bir örnekten
    # geliyor; buradan DURGUN 0.5 ve HAREKET ~2 çıkabiliyordu ve gece kızıl
    # ötesi gürültüsü ikisinin ARASINA düşer: her kare durgun sayacını sıfırlar,
    # hiçbir araç "durmaz", hiçbir şey gönderilmez — kalp atışı sürdüğü için
    # de sunucu ve `durum` köprüyü sağlıklı gösterir. Varsayılanlar sahada
    # çalıştığı bilinen değerler; daha hassası, o tek gece riskine değmez.
    durgun = max(2.0, round(taban * 1.5, 1))
    hareket = max(6.0, durgun + 1.0, round(min(tepe * 0.5, taban * 4 + 2), 1))
    return durgun, hareket
