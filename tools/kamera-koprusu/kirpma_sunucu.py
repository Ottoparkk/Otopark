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
 .mod{background:#1c1f24;color:#ececec;border:1px solid #2a2f36;
      padding:10px 16px;margin:0 8px 8px 0}
 .mod.secili{border-color:#5ecfe8;color:#5ecfe8}
 .mod.haric.secili{border-color:#f87171;color:#f87171}
 .mod:disabled{opacity:.4;cursor:not-allowed}
 .ipuc{background:#1c1f24;border-left:3px solid #5ecfe8;border-radius:8px;
       padding:12px 14px;margin:16px 0;color:#c9ced6;font-size:14px}
</style></head><body><div class="sar">
<h1>Kırpma kutusunu seçin</h1>
<p class="alt">Şeridi kapsayan dikdörtgeni fareyle sürükleyin: sol ve sağ kenar
şeridin genişliği (sokak girmesin), üst kenar araçların durduğu yerin biraz
üstü. Kutu plakaya yapışmasın — plakayı bu bilgisayar kendisi bulur.</p>

<div class="ipuc" id="bekle">Kameradan görüntü bekleniyor… Birkaç saniye içinde
gelmezse kameranın açık ve bu bilgisayarla aynı ağda olduğunu kontrol edin.</div>
<div class="tuval"><canvas id="t"></canvas></div>

<div class="kutu">
  <div class="kart"><b>Kırpma</b><span id="olcu">—</span></div>
  <div class="kart"><b>Okunabilirlik</b><span id="kalite">—</span></div>
  <div class="kart"><b>Hariç alan</b><span id="haricOlcu">Yok</span></div>
  <div class="kart"><b>Hareket (canlı)</b><span id="hareket">—</span></div>
</div>

<div>
  <button class="mod secili" id="kutuCiz">Kutuyu çiz</button>
  <button class="mod haric" id="haricCiz" disabled>Hariç alan çiz</button>
  <button class="mod" id="haricSil" disabled>Hariç alanı sil</button>
</div>

<div class="ipuc">Kutunun içinde park etmiş araçlar görünüyorsa
<b>Hariç alan çiz</b>'e basıp onların üstüne ikinci bir dikdörtgen çizin.
Orası gri boyanır: hareketi sayılmaz, plakası okunmaz, fotoğrafta da
görünmez.</div>

<div class="ipuc" id="ipuc">Kutuyu çizin. Uzun kenarı <b>200 pikselin</b>
altında kalırsa plaka güvenilir okunmaz — kamerayı yaklaştırın ya da zoom
yapın.</div>

<button class="bas" id="kaydet" disabled>Kaydet ve devam et</button>
<button class="ikinci" id="tumu">Tüm kareyi kullan</button>
</div><script>
const t=document.getElementById('t'),c=t.getContext('2d');
// mod: 'kutu' kırpma kutusunu, 'haric' kutunun içindeki hariç alanı çizer.
let img=new Image(),kutu=null,haric=null,mod='kutu',ciz=false,bas=null,kaynak=[0,0];

// Hariç alanın kutunun İÇİNDE kalan kısmı (kaydedilen de bu); kesişmiyorsa null.
function haricKirp(k){
  if(!haric||!k)return null;
  const x0=Math.max(haric.x,k.x),y0=Math.max(haric.y,k.y),
        x1=Math.min(haric.x+haric.w,k.x+k.w),y1=Math.min(haric.y+haric.h,k.y+k.h);
  if(x1<=x0||y1<=y0)return null;
  return {x:x0,y:y0,w:x1-x0,h:y1-y0};
}
function tamami(h,k){return h&&k&&h.x===k.x&&h.y===k.y&&h.w===k.w&&h.h===k.h;}

function boya(){
  if(!img.width)return;
  t.width=img.width;t.height=img.height;kaynak=[img.width,img.height];
  c.drawImage(img,0,0);
  const lw=Math.max(2,img.width/400);
  if(kutu){
    c.strokeStyle='#5ecfe8';c.lineWidth=lw;
    c.setLineDash([]);c.strokeRect(kutu.x,kutu.y,kutu.w,kutu.h);
    c.fillStyle='rgba(94,207,232,.15)';c.fillRect(kutu.x,kutu.y,kutu.w,kutu.h);
  }
  // Kutunun içindeyse kaydedilecek (kırpılmış) hâli çizilir: görülen = saklanan.
  const h=haricKirp(kutu)||haric;
  if(h){
    c.save();
    c.beginPath();c.rect(h.x,h.y,h.w,h.h);c.clip();
    c.fillStyle='rgba(248,113,113,.25)';c.fillRect(h.x,h.y,h.w,h.h);
    c.strokeStyle='rgba(248,113,113,.7)';c.lineWidth=lw;
    const ara=Math.max(12,img.width/80);
    c.beginPath();
    for(let i=-h.h;i<h.w;i+=ara){c.moveTo(h.x+i,h.y+h.h);c.lineTo(h.x+i+h.h,h.y);}
    c.stroke();c.restore();
    c.strokeStyle='#f87171';c.lineWidth=lw;c.setLineDash([]);
    c.strokeRect(h.x,h.y,h.w,h.h);
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
  const r={x:Math.min(bas.x,p.x),y:Math.min(bas.y,p.y),
           w:Math.abs(p.x-bas.x),h:Math.abs(p.y-bas.y)};
  if(mod==='haric')haric=r;else kutu=r;
  boya();guncelle();
});
t.addEventListener('pointerup',()=>{
  ciz=false;
  // Tek tıklama ya da kıl kadar bir dikdörtgen hariç alan sayılmaz.
  if(mod==='haric'&&haric&&(haric.w<8||haric.h<8)){haric=null;boya();}
  guncelle();
});
function modSec(m){mod=m;guncelle();}
function guncelle(){
  const o=document.getElementById('olcu'),k=document.getElementById('kalite'),
        b=document.getElementById('kaydet'),ho=document.getElementById('haricOlcu'),
        hc=document.getElementById('haricCiz'),hs=document.getElementById('haricSil');
  const kutuVar=kutu&&kutu.w>=8&&kutu.h>=8;
  if(!kutuVar&&mod==='haric')mod='kutu';
  hc.disabled=!kutuVar;hs.disabled=!haric;
  document.getElementById('kutuCiz').classList.toggle('secili',mod==='kutu');
  hc.classList.toggle('secili',mod==='haric');
  t.style.cursor='crosshair';
  if(!kutuVar){
    o.textContent='—';k.textContent='—';b.disabled=true;
    ho.textContent=haric?'—':'Yok';ho.className='';return;
  }
  o.textContent=kutu.w+'×'+kutu.h+' px';
  const uzun=Math.max(kutu.w,kutu.h),iyi=uzun>=200;
  k.textContent=iyi?'Yeterli':'Çok küçük';
  k.className=iyi?'iyi':'kotu';
  // Kutunun dışında kalan ya da kutunun tamamını kaplayan bir hariç alan
  // kaydedilemez (sunucu ve köprü de reddeder): Kaydet kapalı, sebep yazılı.
  let haricTamam=true;
  const h=haricKirp(kutu);
  if(!haric){ho.textContent='Yok';ho.className='';}
  else if(!h){ho.textContent='Kutunun dışında';ho.className='kotu';haricTamam=false;}
  else if(tamami(h,kutu)){ho.textContent='Kutunun tamamı';ho.className='kotu';haricTamam=false;}
  else{ho.textContent=h.w+'×'+h.h+' px';ho.className='';}
  b.disabled=!haricTamam;
}
document.getElementById('kutuCiz').onclick=()=>modSec('kutu');
document.getElementById('haricCiz').onclick=()=>modSec('haric');
document.getElementById('haricSil').onclick=()=>{haric=null;mod='kutu';boya();guncelle();};
document.getElementById('kaydet').onclick=()=>gonder(kutu);
// "Tüm kare"de kesilecek bir kutu yok: hariç alan da gönderilmez.
document.getElementById('tumu').onclick=()=>gonder(null);
function gonder(k){
  // Kutu KARENİN içine sıkıştırılır: fare tuvalin dışına sürüklenince
  // koordinatlar eksiye ya da karenin ötesine taşabiliyor.
  let govde=null;
  if(k){
    const x=Math.max(0,Math.min(k.x,kaynak[0]-1)),y=Math.max(0,Math.min(k.y,kaynak[1]-1));
    k={x:x,y:y,w:Math.max(1,Math.min(k.x+k.w,kaynak[0])-x),
       h:Math.max(1,Math.min(k.y+k.h,kaynak[1])-y)};
    // Hariç alan sıkıştırılmış kutuya göre kırpılır; ortada kalmıyorsa
    // sessizce düşürülmez, kullanıcıya söylenir.
    const h=haricKirp(k);
    if(haric&&(!h||tamami(h,k))){
      document.getElementById('ipuc').textContent=
        'Hariç alan kutunun dışında ya da kutunun tamamını kaplıyor. Hariç alanı silin ya da yeniden çizin.';
      return;
    }
    govde=Object.assign({},k,{haric:h});
  }
  fetch('/kaydet',{method:'POST',
    headers:{'Content-Type':'application/json','X-Otopark-Belirtec':'__BELIRTEC__'},
    body:JSON.stringify(govde)}).then(r=>{
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
        # 1.3.0: kutunun içinde griye boyanan alan (park etmiş araçlar).
        self.haric: tuple[int, int, int, int] | None = None
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
        Aynı yardımcılar kullanılıyor ki iki taraf ayrışamasın — hariç alan
        da köprüdeki gibi griye boyanır (kirp_maskeli), oradaki hareket
        eşiklere girmez.
        """
        # Geç içe aktarma: kopru modülün tamamını (dolayısıyla `requests`'i)
        # gerektiriyor; kırpma sayfası onsuz da içe aktarılabilmeli.
        from kopru import fark, gri_kucuk, kirp_maskeli, olcekle

        g = gri_kucuk(kare)
        h = fark(self._onceki, g)
        with self.kilit:
            kutu, haric = self.kutu, self.haric
        kg = gri_kucuk(olcekle(kirp_maskeli(kare, kutu, haric))) if kutu else None
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


def _dikdortgen(veri) -> tuple[int, int, int, int] | None:
    """{x, y, w, h} → demet; dört değer GERÇEK tamsayı, konum ≥ 0, boyut > 0."""
    if not isinstance(veri, dict):
        return None
    try:
        x, y, w, h = (veri[k] for k in ("x", "y", "w", "h"))
    except KeyError:
        return None
    for v in (x, y, w, h):
        if isinstance(v, bool) or not isinstance(v, int):
            return None
    if x < 0 or y < 0 or w <= 0 or h <= 0:
        return None
    return x, y, w, h


def _kutu_coz(veri) -> tuple[bool, tuple[int, int, int, int] | None,
                             tuple[int, int, int, int] | None]:
    """
    /kaydet gövdesi: `null` = tüm kare, ya da {x, y, w, h} — 1.3.0'dan beri
    isteğe bağlı bir "haric": {x, y, w, h} ile. (geçerli mi, kutu, hariç alan)

    Değerler GERÇEK tamsayı olmalı (bool ve kesir değil), konum negatif
    olamaz, boyut pozitif olmalı. Kutu ayar dosyasına ve oradan köprüye
    gidiyor; orada patlayacak bir değeri burada reddetmek, kurulum bittikten
    sonra başlamayan bir köprüden iyidir.

    Hariç alan kutunun İÇİNE kırpılarak döner (sayfa da öyle çizer: görülen =
    saklanan). Kutuyla kesişmeyen ya da kutunun tamamını kaplayan hariç alan
    isteği reddettirir — köprü de aynı ikisini kabul etmez (kopru.kirpma_haric).
    """
    if veri is None:
        return True, None, None
    kutu = _dikdortgen(veri)
    if kutu is None:
        return False, None, None
    ham = veri.get("haric")
    if ham is None:
        return True, kutu, None
    h = _dikdortgen(ham)
    if h is None:
        return False, None, None
    kx, ky, kw, kh = kutu
    x0, y0 = max(h[0], kx), max(h[1], ky)
    x1, y1 = min(h[0] + h[2], kx + kw), min(h[1] + h[3], ky + kh)
    if x1 <= x0 or y1 <= y0:
        return False, None, None
    haric = (x0, y0, x1 - x0, y1 - y0)
    if haric == kutu:
        return False, None, None
    return True, kutu, haric


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
            gecerli, kutu, haric = _kutu_coz(veri)
            if not gecerli:
                self._yaz(400, "application/json", b'{"hata":"kutu"}')
                return
            # Sonuç, cevap yazılmadan ÖNCE işaretlenir: sunucu iş parçacıklı,
            # ve tarayıcı cevabı aldığı anda sihirbazın da bunu görmüş olması
            # gerekir. kirpma_sec kapatmadan önce kısa bir süre bekliyor, yani
            # bu cevap yine de gider.
            sonuc["kutu"] = kutu
            sonuc["haric"] = haric
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
                                                  tuple[int, int, int, int] | None,
                                                  list[float]]:
    """
    Tarayıcıyı açar, kullanıcı kutuyu çizene kadar bekler.

    Döndürür: (kutu ya da None, hariç alan ya da None, eşik önerisi için
    hareket değerleri). Kutu None = "tüm kareyi kullan". Kutu seçildiyse
    hareket değerleri o KUTUNUN içinden, hariç alan griye boyanmış olarak
    ölçülür (bkz. _Durum.olcum_ekle).
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
    haric = sonuc.get("haric") if kutu else None
    if kutu:
        # Kutu ancak şimdi biliniyor. Birkaç saniye daha izlenip hareket bu
        # kez kutunun içinde ölçülür; eşikler bundan çıkar.
        print("  Seçilen kutuda hareket ölçülüyor…", flush=True)
        with d.kilit:
            d.kutu, d.haric = kutu, haric
        time.sleep(KIRPIK_OLCUM_SN)
    d.dur = True
    with d.kilit:
        olcumler = esik_secimi(kutu, list(d.hareketler), list(d.kirpik_hareketler))
    return kutu, haric, olcumler


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
