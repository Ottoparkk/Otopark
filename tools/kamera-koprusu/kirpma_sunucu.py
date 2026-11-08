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
<title>Otopark — Kırpma Alanı</title>
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
 .mod.kapi.secili{border-color:#fbbf24;color:#fbbf24}
 .mod:disabled{opacity:.4;cursor:not-allowed}
 .ipuc{background:#1c1f24;border-left:3px solid #5ecfe8;border-radius:8px;
       padding:12px 14px;margin:16px 0;color:#c9ced6;font-size:14px}
 .ipuc.kapi{border-left-color:#fbbf24}
</style></head><body><div class="sar">
<h1>Kırpma alanını seçin</h1>
<p class="alt">Görüntüye tıklayarak alanın köşelerini sırayla işaretleyin
(en çok 8). İlk köşeye yeniden tıklayınca alan kapanır. Park etmiş araçları
alanın DIŞINDA bırakın: oralar gri boyanır, hareketi sayılmaz, plakası
okunmaz, fotoğrafta da görünmez.</p>

<div class="ipuc" id="bekle">Kameradan görüntü bekleniyor… Birkaç saniye içinde
gelmezse kameranın açık ve bu bilgisayarla aynı ağda olduğunu kontrol edin.</div>
<div class="tuval"><canvas id="t"></canvas></div>

<div class="kutu">
  <div class="kart"><b>Kırpma</b><span id="olcu">—</span></div>
  <div class="kart"><b>Okunabilirlik</b><span id="kalite">—</span></div>
  <div class="kart"><b>Kapı alanı</b><span id="kapiOlcu">Yok</span></div>
  <div class="kart"><b>Hareket (canlı)</b><span id="hareket">—</span></div>
</div>

<div>
  <button class="mod secili" id="alanCiz">Kırpma alanı</button>
  <button class="mod kapi" id="kapiCiz">Kapı alanı</button>
  <button class="mod" id="geriAl">Son köşeyi sil</button>
  <button class="mod" id="alanSil">Alanı sil</button>
</div>

<div class="ipuc kapi"><b>Kapı alanı</b>: kapının önü — araçların girip
çıktığı yer. Resmin kenarına kadar çizin, içine en az bir araç boyu girsin;
araçların PARK ETMEDİĞİ bir yer olsun. Köprü bir aracı ancak buradan girip
otoparka geçtiyse "girdi", otoparktan gelip burada kaybolduysa "çıktı" sayar;
otopark içindeki hareket sayılmaz. Çizilmezse araçlar durunca ya da
kaybolunca sayılır.</div>

<div class="ipuc" id="ipuc">Kırpma alanını çizin. Uzun kenarı <b>200 pikselin</b>
altında kalırsa plaka güvenilir okunmaz — kamerayı yaklaştırın ya da zoom
yapın.</div>

<button class="bas" id="kaydet" disabled>Kaydet ve devam et</button>
<button class="ikinci" id="tumu">Tüm kareyi kullan</button>
</div><script>
const t=document.getElementById('t'),c=t.getContext('2d');
// 1.4.0: iki çokgen. mod 'alan' kırpma alanını, 'kapi' kapı alanını çizer.
// Köşeler KAYNAK pikselde; kapanan alan kaydedilir. Kurallar sunucuda
// (kirpma_sunucu._alan_coz → plaka.cokgen_coz) esastır; buradaki yapıştırma
// ve denetim yalnızca görüntü için aynı hesaptır.
const COKGEN_EN_COK=8,YAPIS=0.03;
let img=new Image(),mod='alan',kaynak=[0,0];
const cizim={alan:{n:[],kapali:false},kapi:{n:[],kapali:false}};

function sinirlar(m){
  if(m==='kapi'&&cizim.alan.kapali){
    const xs=cizim.alan.n.map(p=>p[0]),ys=cizim.alan.n.map(p=>p[1]);
    return [Math.min(...xs),Math.min(...ys),Math.max(...xs),Math.max(...ys)];
  }
  return [0,0,kaynak[0],kaynak[1]];
}
// Kenara %3'ten yakın köşe kenara yapışır (kirpma_sunucu._yapistir ile aynı).
function yapistir(p,m){
  const [x0,y0,x1,y1]=sinirlar(m),px=YAPIS*(x1-x0),py=YAPIS*(y1-y0);
  let x=Math.max(0,Math.min(p[0],kaynak[0])),y=Math.max(0,Math.min(p[1],kaynak[1]));
  if(x>=x0-px&&x<=x0+px)x=x0;if(x>=x1-px&&x<=x1+px)x=x1;
  if(y>=y0-py&&y<=y0+py)y=y0;if(y>=y1-py&&y<=y1+py)y=y1;
  return [Math.round(x),Math.round(y)];
}
function yon(a,b,c){const v=(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);return v>0?1:v<0?-1:0;}
function ustunde(a,b,c){return Math.min(a[0],b[0])<=c[0]&&c[0]<=Math.max(a[0],b[0])&&
  Math.min(a[1],b[1])<=c[1]&&c[1]<=Math.max(a[1],b[1]);}
function kesisir(a,b,c,d){
  const y1=yon(a,b,c),y2=yon(a,b,d),y3=yon(c,d,a),y4=yon(c,d,b);
  if(y1!==y2&&y3!==y4)return true;
  return (y1===0&&ustunde(a,b,c))||(y2===0&&ustunde(a,b,d))||(y3===0&&ustunde(c,d,a))||(y4===0&&ustunde(c,d,b));
}
// plaka.cokgen_coz ile aynı: 3-8 köşe, aynı köşe yok, kenarlar kesişmez, alan ≥ 64.
function gecerli(n){
  const k=n.length;
  if(k<3||k>COKGEN_EN_COK)return false;
  if(new Set(n.map(p=>p[0]+','+p[1])).size!==k)return false;
  for(let i=0;i<k;i++)for(let j=i+1;j<k;j++){
    if(j===i+1||(i===0&&j===k-1))continue;
    if(kesisir(n[i],n[(i+1)%k],n[j],n[(j+1)%k]))return false;
  }
  let a=0;for(let i=0;i<k;i++){const p=n[i],q=n[(i+1)%k];a+=p[0]*q[1]-q[0]*p[1];}
  return Math.abs(a)/2>=64;
}
function yol(n,kapat){
  c.beginPath();n.forEach((p,i)=>i?c.lineTo(p[0],p[1]):c.moveTo(p[0],p[1]));
  if(kapat)c.closePath();
}
function boya(){
  if(!img.width)return;
  t.width=img.width;t.height=img.height;kaynak=[img.width,img.height];
  c.drawImage(img,0,0);
  const lw=Math.max(2,img.width/400),r=Math.max(5,img.width/200);
  const a=cizim.alan;
  if(a.kapali){
    // Alanın DIŞI karartılır: köprünün griye boyadığı yer.
    c.save();c.beginPath();c.rect(0,0,img.width,img.height);
    a.n.forEach((p,i)=>i?c.lineTo(p[0],p[1]):c.moveTo(p[0],p[1]));c.closePath();
    c.fillStyle='rgba(20,22,26,.65)';c.fill('evenodd');c.restore();
  }
  [['alan','#5ecfe8'],['kapi','#fbbf24']].forEach(([m,renk])=>{
    const z=cizim[m];if(!z.n.length)return;
    if(m==='kapi'&&z.kapali){
      c.save();yol(z.n,true);c.clip();
      c.fillStyle='rgba(251,191,36,.18)';c.fillRect(0,0,img.width,img.height);c.restore();
    }
    c.strokeStyle=renk;c.lineWidth=lw;c.setLineDash(z.kapali?[]:[lw*4,lw*3]);
    yol(z.n,z.kapali);c.stroke();c.setLineDash([]);
    c.fillStyle=renk;z.n.forEach(p=>{c.beginPath();c.arc(p[0],p[1],r,0,7);c.fill();});
  });
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
// yoksa kaydedilen alan görülenden başka bir yeri gösterir.
function nokta(e){
  const r=t.getBoundingClientRect();
  return [Math.round((e.clientX-r.left)*(t.width/r.width)),
          Math.round((e.clientY-r.top)*(t.height/r.height))];
}
t.addEventListener('pointerdown',e=>{
  if(!img.width)return;
  const z=cizim[mod];if(z.kapali)return;
  const p=yapistir(nokta(e),mod);
  // İlk köşeye (yakınına) tıklamak alanı kapatır.
  if(z.n.length>=3){
    const q=z.n[0],yakin=Math.max(12,img.width/60);
    if(Math.hypot(p[0]-q[0],p[1]-q[1])<=yakin){z.kapali=true;boya();guncelle();return;}
  }
  z.n.push(p);
  if(z.n.length>=COKGEN_EN_COK)z.kapali=true;
  boya();guncelle();
});
function modSec(m){mod=m;guncelle();}
function geriAl(){const z=cizim[mod];if(z.kapali)z.kapali=false;else z.n.pop();boya();guncelle();}
function alanSil(){const z=cizim[mod];z.n=[];z.kapali=false;boya();guncelle();}
function guncelle(){
  const o=document.getElementById('olcu'),k=document.getElementById('kalite'),
        b=document.getElementById('kaydet'),ko=document.getElementById('kapiOlcu'),
        ip=document.getElementById('ipuc');
  document.getElementById('alanCiz').classList.toggle('secili',mod==='alan');
  document.getElementById('kapiCiz').classList.toggle('secili',mod==='kapi');
  const a=cizim.alan,g=cizim.kapi;
  const alanTamam=a.kapali&&gecerli(a.n),kapiTamam=!g.n.length||(g.kapali&&gecerli(g.n));
  if(a.kapali&&!alanTamam)ip.textContent='Kırpma alanının kenarları birbirini kesiyor ya da alan çok küçük — Son köşeyi sil ile düzeltin.';
  else if(g.kapali&&!kapiTamam)ip.textContent='Kapı alanının kenarları birbirini kesiyor ya da alan çok küçük — Son köşeyi sil ile düzeltin.';
  else if(g.n.length&&!g.kapali)ip.textContent='Kapı alanını kapatmak için ilk köşesine tıklayın.';
  else if(a.n.length&&!a.kapali)ip.textContent='Kırpma alanını kapatmak için ilk köşesine tıklayın.';
  else if(!a.n.length)ip.textContent='Kırpma alanını çizin. Uzun kenarı 200 pikselin altında kalırsa plaka güvenilir okunmaz.';
  else if(!g.n.length)ip.textContent='Şimdi Kapı alanı ile kapının önünü çizin (ya da kapı alanı olmadan kaydedin).';
  else ip.textContent='Alanlar hazır — Kaydet ve devam et.';
  ko.textContent=!g.n.length?'Yok':g.kapali?g.n.length+' köşe':'Çiziliyor';
  ko.className=g.kapali&&!kapiTamam?'kotu':'';
  if(!alanTamam){o.textContent='—';k.textContent='—';k.className='';b.disabled=true;return;}
  const xs=a.n.map(p=>p[0]),ys=a.n.map(p=>p[1]);
  const w=Math.max(...xs)-Math.min(...xs),h=Math.max(...ys)-Math.min(...ys);
  o.textContent=w+'×'+h+' px';
  const iyi=Math.max(w,h)>=200;
  k.textContent=iyi?'Yeterli':'Çok küçük';k.className=iyi?'iyi':'kotu';
  b.disabled=!kapiTamam;
}
document.getElementById('alanCiz').onclick=()=>modSec('alan');
document.getElementById('kapiCiz').onclick=()=>modSec('kapi');
document.getElementById('geriAl').onclick=geriAl;
document.getElementById('alanSil').onclick=alanSil;
document.getElementById('kaydet').onclick=()=>gonder(true);
// "Tüm kare"de kırpma yok; kapanmış bir kapı alanı varsa o yine gönderilir.
document.getElementById('tumu').onclick=()=>gonder(false);
function gonder(alanla){
  const g=cizim.kapi,kapi=g.kapali&&gecerli(g.n)?g.n:null;
  if(g.n.length&&!kapi){
    document.getElementById('ipuc').textContent='Kapı alanı kapanmadı ya da geçersiz: düzeltin ya da Alanı sil ile kaldırın.';
    return;
  }
  const govde={alan:alanla?cizim.alan.n:null,kapi:kapi};
  fetch('/kaydet',{method:'POST',
    headers:{'Content-Type':'application/json','X-Otopark-Belirtec':'__BELIRTEC__'},
    body:JSON.stringify(govde)}).then(r=>{
      // Reddedilen bir kayıt "Kaydedildi" DEMEMELİ: sihirbaz hâlâ bekliyor.
      if(!r.ok){
        document.getElementById('ipuc').textContent=
          'Kaydedilemedi: alanlar geçersiz ya da kapı alanı kırpma alanıyla hiç kesişmiyor. Düzeltip tekrar deneyin.';
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
        self.haric: tuple | None = None          # ((x, y, w, h), …) — 1.3.3: en çok 3
        # 1.4.0: kırpma ALANI (çokgen); verilmişse dışı griye boyanır, haric kullanılmaz.
        self.alan: tuple | None = None
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
            kutu, haric, alan = self.kutu, self.haric, self.alan
        kg = gri_kucuk(olcekle(kirp_maskeli(kare, kutu, haric, alan))) if kutu else None
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


def _kutu_coz(veri) -> tuple[bool, tuple[int, int, int, int] | None, tuple | None]:
    """
    /kaydet gövdesi: `null` = tüm kare, ya da {x, y, w, h} — isteğe bağlı bir
    "haric" ile: 1.3.3'ten beri en çok 3 dikdörtgenlik LİSTE ([{x,y,w,h}, …]);
    1.3.0'ın tek nesnesi ve `null` / `[]` de kabul edilir.
    (geçerli mi, kutu, kesilen köşeler ((x, y, w, h), …) ya da None)

    Değerler GERÇEK tamsayı olmalı (bool ve kesir değil), konum negatif
    olamaz, boyut pozitif olmalı. Kutu ayar dosyasına ve oradan köprüye
    gidiyor; orada patlayacak bir değeri burada reddetmek, kurulum bittikten
    sonra başlamayan bir köprüden iyidir.

    Her alan kutunun İÇİNE kırpılarak döner (sayfa da öyle çizer: görülen =
    saklanan). Kutuyla kesişmeyen bir alan, 3'ten fazla alan ya da kutunun
    tamamını BİRLİKTE kaplayan alanlar isteği reddettirir — köprü de aynısını
    kabul etmez (kopru.haric_metni_coz).
    """
    import plaka
    if veri is None:
        return True, None, None
    kutu = _dikdortgen(veri)
    if kutu is None:
        return False, None, None
    ham = veri.get("haric")
    if ham is None or ham == []:
        return True, kutu, None
    liste = [ham] if isinstance(ham, dict) else ham
    if not isinstance(liste, list) or len(liste) > plaka.HARIC_EN_COK:
        return False, None, None
    kx, ky, kw, kh = kutu
    alanlar = []
    for oge in liste:
        h = _dikdortgen(oge)
        if h is None:
            return False, None, None
        x0, y0 = max(h[0], kx), max(h[1], ky)
        x1, y1 = min(h[0] + h[2], kx + kw), min(h[1] + h[3], ky + kh)
        if x1 <= x0 or y1 <= y0:
            return False, None, None
        alanlar.append((x0, y0, x1 - x0, y1 - y0))
    if plaka.kesilen_alan(kx, ky, kx + kw, ky + kh, alanlar) >= kw * kh:
        return False, None, None
    return True, kutu, tuple(alanlar)


# 1.4.0: kenara bu oranda (genişlik / yükseklik) yakın köşe kenara yapışır.
# Sayfanın YAPIS sabitiyle aynı; esas olan buradaki hesap.
YAPIS = 0.03


def _yapistir(noktalar, x0: int, y0: int, x1: int, y1: int) -> list:
    """Dikdörtgenin kenarına %YAPIS'tan yakın (ya da dışına taşan) köşeyi kenara çeker."""
    px, py = YAPIS * (x1 - x0), YAPIS * (y1 - y0)
    sonuc = []
    for x, y in noktalar:
        x = x0 if x <= x0 + px and x >= x0 - px else x
        x = x1 if x1 - px <= x <= x1 + px else x
        y = y0 if y <= y0 + py and y >= y0 - py else y
        y = y1 if y1 - py <= y <= y1 + py else y
        sonuc.append((x, y))
    return sonuc


def _cokgen_ham(ham) -> tuple | None:
    """JSON köşe listesi → doğrulanmış köşeler (plaka.cokgen_coz); bozuksa None."""
    import plaka
    if not isinstance(ham, list):
        return None
    try:
        return plaka.cokgen_coz(ham)
    except ValueError:
        return None


def _alan_coz(veri: dict, en: int | None, boy: int | None):
    """
    1.4.0 gövdesi {"alan": [[x, y], …] | null, "kapi": [[x, y], …] | null}
    → (geçerli mi, alan ya da None, kapı ya da None). Köşeler önce
    doğrulanır, sonra kenara yapıştırılıp karenin içine sıkıştırılır ve
    YENİDEN doğrulanır (yapışma aynı köşeyi iki kez üretebilir). Kare boyutu
    bilinmiyorsa (kamera henüz kare vermedi — sayfa çizemezdi) reddedilir.
    """
    import plaka
    if en is None or boy is None:
        return False, None, None
    alan = kapi = None
    if veri.get("alan") is not None:
        ham = _cokgen_ham(veri["alan"])
        if ham is None:
            return False, None, None
        sikis = [(min(max(x, 0), en), min(max(y, 0), boy)) for x, y in ham]
        alan = _cokgen_ham([list(n) for n in _yapistir(sikis, 0, 0, en, boy)])
        if alan is None:
            return False, None, None
    if veri.get("kapi") is not None:
        ham = _cokgen_ham(veri["kapi"])
        if ham is None:
            return False, None, None
        sikis = [(min(max(x, 0), en), min(max(y, 0), boy)) for x, y in ham]
        if alan is not None:
            ax, ay = [p[0] for p in alan], [p[1] for p in alan]
            sinir = (min(ax), min(ay), max(ax), max(ay))
        else:
            sinir = (0, 0, en, boy)
        kapi = _cokgen_ham([list(n) for n in _yapistir(sikis, *sinir)])
        if kapi is None:
            return False, None, None
        # Kırpmayla kesişmeyen kapı alanını köprü hiçbir zaman göremezdi.
        k = plaka.cokgen_dis_maskesi(kapi, en, boy) == 0
        if alan is not None:
            k &= plaka.cokgen_dis_maskesi(alan, en, boy) == 0
        if not k.any():
            return False, None, None
    return True, alan, kapi


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
            alan = kapi = None
            if isinstance(veri, dict) and ("alan" in veri or "kapi" in veri):
                # 1.4.0: köşeleri tıklanan kırpma alanı ve kapı alanı.
                with d.kilit:
                    sekil = None if d.kare is None else d.kare.shape
                gecerli, alan, kapi = _alan_coz(veri, sekil and sekil[1], sekil and sekil[0])
                haric = None
                import plaka
                kutu = plaka.cokgen_kutusu(alan) if gecerli and alan is not None else None
            else:
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
            sonuc["alan"] = alan
            sonuc["kapi"] = kapi
            bitti.set()
            self._yaz(200, "application/json", b'{"ok":true}')

    # İş parçacıklı: tarayıcılar sayfanın adresine yedek, BOŞ bağlantılar
    # açar. Tek iş parçacıklı sunucu onlardan birini okurken takılıyor ve
    # saniyede bir gelen kare/hareket istekleri o soket kapanana kadar
    # bekliyordu — sayfa donmuş görünüyordu.
    sunucu = ThreadingHTTPServer(("127.0.0.1", port), Isleyici)
    sunucu.daemon_threads = True
    return sunucu, sonuc, bitti, belirtec


def kirpma_sec(rtsp: str, port: int = 0) -> tuple:
    """
    Tarayıcıyı açar, kullanıcı alanı çizene kadar bekler.

    Döndürür: (kutu ya da None, hariç alan ya da None, eşik önerisi için
    hareket değerleri, kırpma alanı ya da None, kapı alanı ya da None).
    Kutu None = "tüm kareyi kullan". 1.4.0 sayfası çokgen gönderir: kutu =
    alanın çevreleyen dikdörtgeni, hariç alan None. Kutu seçildiyse hareket
    değerleri o KUTUNUN içinden, alanın dışı (ya da hariç alan) griye
    boyanmış olarak ölçülür (bkz. _Durum.olcum_ekle).
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
    alan = sonuc.get("alan") if kutu else None
    kapi = sonuc.get("kapi")
    if kutu:
        # Kutu ancak şimdi biliniyor. Birkaç saniye daha izlenip hareket bu
        # kez kutunun içinde ölçülür; eşikler bundan çıkar.
        print("  Seçilen alanda hareket ölçülüyor…", flush=True)
        with d.kilit:
            d.kutu, d.haric, d.alan = kutu, haric, alan
        time.sleep(KIRPIK_OLCUM_SN)
    d.dur = True
    with d.kilit:
        olcumler = esik_secimi(kutu, list(d.hareketler), list(d.kirpik_hareketler))
    return kutu, haric, olcumler, alan, kapi


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
