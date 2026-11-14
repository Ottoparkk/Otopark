# -*- coding: utf-8 -*-
"""
Mutasyon sınaması (1.3.0) — testler kuralları GERÇEKTEN tutuyor mu?

    python test_mutasyon.py

Her satırda bir kural bilerek bozulur ve onu tutan testin DÜŞMESİ beklenir.
Düşmeyen test, kuralı tutmuyor demektir. Bozma, köprü klasörünün GEÇİCİ bir
kopyasında yapılır: depodaki dosyalara dokunulmaz, hiçbir şey silinmez
(geçici klasörlerin yolu sonunda yazılır, elle temizlenir).

Önce her test BOZULMADAN koşulur ve geçmelidir — yoksa "düştü" sonucu
anlamsız olurdu. Bozulacak metin dosyada tam bir kez geçmelidir; geçmiyorsa
(kod değişmiş) sınama durur ve hangi satırın güncellenmesi gerektiğini söyler.
Gerçek modelleri kullanan test yok; paket venv'i gerekmez.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

for _a in (sys.stdout, sys.stderr):
    if hasattr(_a, "reconfigure"):
        _a.reconfigure(encoding="utf-8", errors="replace")

BURASI = os.path.dirname(os.path.abspath(__file__))
DEPO = os.path.abspath(os.path.join(BURASI, "..", ".."))
# Testlerin okuduğu sunucu dosyaları (kural metni sunucununkiyle karşılaştırılır).
SUNUCU_DOSYALARI = ["supabase/functions/_shared/vlm.ts", "supabase/functions/_shared/serit.ts"]


def _fn(modul: str, fonk: str) -> list[str]:
    return [sys.executable, "-c",
            f"import sys; sys.path.insert(0, '.'); import {modul} as t; t.{fonk}()"]


def _senaryo(ad: str) -> list[str]:
    return [sys.executable, "test_kopru.py", ad]


def _dosya(ad: str) -> list[str]:
    return [sys.executable, ad]


# (açıklama, dosya, bozulacak metin, yerine, test komutu)
MUTASYONLAR = [
    ("iki kırpıntı aynı metni vermeli", "plaka.py",
     "if o1[0] == o2[0] and min(o1[1], o2[1]) >= esik:", "if min(o1[1], o2[1]) >= esik:",
     _fn("test_plaka", "test_iki_kirpinti")),
    ("kenara değen plaka kesiktir", "plaka.py",
     "    if k.x1 < px or k.y1 < py or k.x2 > en - px or k.y2 > boy - py:", "    if False:",
     _fn("test_plaka", "test_tam_plaka_kenar_payi")),
    ("hariç alana değen plaka kesiktir", "plaka.py",
     "        if k.x1 < ex2 and k.x2 > ex1 and k.y1 < ey2 and k.y2 > ey1:", "        if False:",
     _fn("test_plaka", "test_tam_plaka_haric_alan")),
    ("tek görünümün kareleri bağımsız oy değil", "plaka.py",
     "emin = (ust_g >= self.k_oy and ust_g >= self.oran * toplam) or (",
     "emin = (ust_g >= 1) or (",
     _fn("test_plaka", "test_oylama_tek_gorunum_cok_kare_emin_degil")),
    ("anlaşmazlıkta çoğunluk şartı", "plaka.py",
     "ust_g >= self.k_oy and ust_g >= self.oran * toplam", "ust_g >= self.k_oy",
     _fn("test_plaka", "test_oylama_anlasmazlik_personele")),
    ("model özeti tutmazsa açılmaz", "plaka.py",
     "        if sha256_dosya(yol) != m.sha256:", "        if False:",
     _fn("test_plaka", "test_yukle_bozuk_model")),
    ("onnxruntime telemetrisi kapalı", "plaka.py",
     '    os.environ["ORT_DISABLE_TELEMETRY"] = "1"', "    pass",
     _fn("test_plaka", "test_onnxruntime_telemetrisi_kapali")),
    ("hariç alandaki kutu düşer", "okuma.py",
     "plaka.haric_orani(k, haric) <= plaka.HARIC_DUSUR", "True",
     _fn("test_okuma", "test_kare_haric_alandaki_kutu_yok_sayilir")),
    ("60 sn içinde aynı plaka ikinci kez gitmez", "okuma.py",
     "simdi - t <= YAKIN_SN", "False",
     _fn("test_okuma", "test_karar_altmis_saniye_ayni_plaka")),
    ("gönderilmiş duran aracın gidişi gönderilmez", "okuma.py",
     "    ayrilis = ayrilis_sahne or (son_durdu_plaka is not None",
     "    ayrilis = ayrilis_sahne and (son_durdu_plaka is not None",
     _fn("test_okuma", "test_karar_arka_planda_gonderilen_plaka_ayrilistir")),
    ("plakalı aracın gidişi 'plakasız duran' değil", "okuma.py",
     "elif durdu and arac_boyu and not arka_kutulu:", "elif durdu and arac_boyu:",
     _fn("test_okuma", "test_karar_arka_planda_arac_vardi_plakasiz_durulma_gidistir")),
    ("plakası görülmeyen duran araç personele", "okuma.py",
     "elif durdu and arac_boyu and not arka_kutulu:", "elif False:",
     _fn("test_okuma", "test_karar_duran_arac_plakasiz_personele")),
    ("bozuk okuyucuda araç personele", "okuma.py",
     "    if bozuk and not k.eminler:", "    if False:",
     _fn("test_okuma", "test_karar_bozuk_okuyucu")),
    ("kutu yalnızca kesin cevapta silinir", "giden.py",
     "        if sonuc in (TAMAM, RED):", "        if True:",
     _dosya("test_giden.py")),
    ("kayda plaka yazılmaz", "kopru.py",
     '    return _PLAKA_GIBI.sub("•••", metin)', "    return metin",
     _fn("test_kurulum", "test_gonderim_kayda_plaka_yazmaz")),
    ("kutunun tamamını (birlikte) kaplayan hariç alanlar reddedilir (köprü)", "kopru.py",
     "    if plaka.kesilen_alan(kx, ky, kx + kw, ky + kh, alanlar) >= kw * kh:", "    if False:",
     _fn("test_kurulum", "test_kirpma_metinleri_cozulur")),
    ("kutunun tamamını (birlikte) kaplayan hariç alanlar reddedilir (sayfa)", "kirpma_sunucu.py",
     "    if plaka.kesilen_alan(kx, ky, kx + kw, ky + kh, alanlar) >= kw * kh:", "    if False:",
     _fn("test_kurulum", "test_kirpma_sunucusu_haric_alan")),
    # ---- 1.3.3: en çok 3 kesilen köşe, iki model aynı anda --------------------
    ("2. ve 3. kesilen köşe de plakayı keser", "plaka.py",
     "    for hx, hy, hw, hh in haric_listesi(haric):",
     "    for hx, hy, hw, hh in haric_listesi(haric)[:1]:",
     _fn("test_plaka", "test_tam_plaka_ikinci_ve_ucuncu_haric_alan")),
    ("üst üste binen kesilen köşeler iki kez sayılmaz", "plaka.py",
     "                yield (1 if n % 2 else -1), (x1, y1, x2, y2)",
     "                yield 1, (x1, y1, x2, y2)",
     _fn("test_plaka", "test_haric_orani_birlesim_cift_sayilmaz")),
    ("her kesilen köşe griye boyanır", "kopru.py",
     "    for a, b, w, hh in alanlar:", "    for a, b, w, hh in alanlar[:1]:",
     _fn("test_kurulum", "test_kirp_maskeli_birden_cok_alan")),
    ("park etmiş aracın plakası 2. kesilen köşede gitmez", "kopru.py",
     "    for a, b, w, hh in alanlar:", "    for a, b, w, hh in alanlar[:1]:",
     _senaryo("ikinci_haric_park_plakali")),
    ("araç bulucu plaka okumayı bekletmez", "okuma.py",
     "            return self._plaka_k.bos()",
     "            return all(k.bos() for k in self._kuyruklar())",
     _fn("test_okuma", "test_isci_yavas_arac_bulucu_plakayi_bekletmez")),
    # ---- 1.3.4: plaka tam çözünürlükten okunur ------------------------------
    ("plaka tam çözünürlükten okunur", "okuma.py",
     "        okumalar = p.oku_cift(tam, plaka.kutu_olcekle(k, tw / w, th / h))",
     "        okumalar = p.oku_cift(kirpik, k)",
     _fn("test_okuma", "test_kutuyu_oku_tam_cozunurlukten")),
    ("kutu doğru oranla taşınır (x ve y ayrı)", "okuma.py",
     "plaka.kutu_olcekle(k, tw / w, th / h)", "plaka.kutu_olcekle(k, th / h, tw / w)",
     _fn("test_okuma", "test_kutuyu_oku_tam_cozunurlukten")),
    ("kesiklik kuralı küçük kırpıntıda kalır", "okuma.py",
     "    if not plaka.tam_mi(k, w, h, haric):", "    if tam is None and not plaka.tam_mi(k, w, h, haric):",
     _fn("test_okuma", "test_kutuyu_oku_tam_cozunurlukten")),
    ("köprü tam çözünürlüğü işe verir", "kopru.py",
     "        tam_var = plaka_tam and maskeli.shape[:2] != kirpik.shape[:2]",
     "        tam_var = False",
     _senaryo("kucuk_kirpik_tam_okuma")),
    ("öncelikli kareler sırayla, biri ötekini ezmez", "okuma.py",
     "            self.oncelik = (self.oncelik + [is_])[-ONCELIK_EN_COK:]",
     "            self.oncelik = [is_]",
     _fn("test_okuma", "test_isci_iki_oncelikli_is_sirayla")),
    ("yeniden kurulum eski hariç alanı siler", "kurulum.py",
     '        ayar["KIRPMA_HARIC"] = ""', "        pass",
     _fn("test_kurulum", "test_haric_alan_ayara_yazilir_ve_yeniden_kurulumda_silinir")),
    ("eski sunucu kurulumda yakalanır", "kurulum.py",
     '    if r.status_code == 200 and isinstance(veri, dict) and veri.get("okunamadi_destekli") is True:',
     "    if True:",
     _fn("test_kurulum", "test_baglanti_testi_eski_sunucuyu_yakalar")),
    ("çalışmayan okuyucu sağlığı bozar", "durum.py",
     "and not ag_yok and not okuyucu_bozuk)", "and not ag_yok)",
     _fn("test_kurulum", "test_durum_plaka_okuyucu_satiri")),
    ("çıkışta okunamayan araç gönderilmez", "kopru.py",
     '    if g.tur == "OKUNAMADI" and YON == "CIKIS":', "    if False:",
     _senaryo("cikis_belirsiz")),
    # ---- 1.3.1 araç bulucu ------------------------------------------------
    ("yalnızca YENİ araç sayılır (aynı yerde duran araç değil)", "okuma.py",
     "if not _onceden_vardi(k, gecis.arka_araclar)),", "if True),",
     _fn("test_okuma", "test_kare_park_etmis_arac_yeni_sayilmaz")),
    ("kural 1: durulan karedeki yeni araç personele", "okuma.py",
     "            elif durdu and arac_durgun is not None and arac_durgun >= arac_esik:",
     "            elif False:",
     _fn("test_okuma", "test_karar_duran_yeni_arac_personele")),
    ("kural 2: geçişte net yeni araç personele (durdu da olsa)", "okuma.py",
     "            elif arac_max is not None and arac_max >= arac_gecis_esik:", "            elif False:",
     _fn("test_okuma", "test_karar_sahadaki_kacirma_personele_gider")),
    ("bulucuyla 1.3.0 gidiş kuralı (önceki karede plaka) kullanılmaz", "okuma.py",
     "        elif yere_bakar:", "        elif yere_bakar and not arka_kutulu:",
     _fn("test_okuma", "test_karar_bulucuyla_onceki_karedeki_plaka_engel_degil")),
    ("durulan kare ölçülmediyse personele", "okuma.py",
     "            elif durdu and arac_durgun is None:", "            elif False:",
     _fn("test_okuma", "test_karar_duran_arac_bilinmiyorsa_personele")),
    ("sahadaki kaçırma: yavaş gelen plakasız araç personele", "okuma.py",
     "if not _onceden_vardi(k, gecis.arka_araclar)),", "if not gecis.arka_araclar),",
     _senaryo("yavas_gelen")),
    ("araç bulucu hatası plaka okumayı durdurmaz", "okuma.py",
     "            except Exception as e:  # noqa: BLE001 — bulucu okuyucuyu öldürmesin",
     "            except ZeroDivisionError as e:",
     _fn("test_okuma", "test_isci_arac_hatasi_okumayi_durdurmaz")),
    ("karar kare süresine göre bekler", "okuma.py",
     "        sure = taban if not sureler else max(taban, BEKLE_KAT * max(sureler))", "        sure = taban",
     _fn("test_okuma", "test_isci_bekleme_suresi_kare_suresine_uyar")),
    ("araç bulucu girdisi BGR, ham (legacy değil)", "arac.py",
     "    return np.ascontiguousarray(tuval.transpose(2, 0, 1)[None], dtype=np.float32), r",
     "    return np.ascontiguousarray(tuval[:, :, ::-1].transpose(2, 0, 1)[None], "
     "dtype=np.float32), r",
     _fn("test_arac", "test_on_isle_bgr_ham_sol_ust")),
    ("kesilen köşedeki araç sayılmaz", "arac.py",
     "    tut = _haric_orani(kutular, haric) <= HARIC_DUSUR",
     "    tut = _haric_orani(kutular, haric) <= 1.0",
     _fn("test_arac", "test_skorla_kesilen_koseyi_atlar")),
    ("araç modeli özeti tutmazsa açılmaz", "arac.py",
     "        if plaka.sha256_dosya(yol) != m.sha256:", "        if False:",
     _fn("test_arac", "test_yukle_bozuk_dosya")),
    # ---- 1.4.2: YOLO11s profili --------------------------------------------------
    ("YOLO11 girdisi RGB 0-1 (YOLOX gibi 0-255 değil)", "arac.py",
     "    return x, (r, dw, dh)", "    return x * 255.0, (r, dw, dh)",
     _fn("test_arac", "test_on_isle11_ortali_rgb01")),
    ("YOLO11 kutusundan letterbox dolgusu çıkar", "arac.py",
     "    kutular -= np.array([dw, dh, dw, dh], dtype=np.float32)", "    pass",
     _fn("test_arac", "test_coz11_kutu_ters_letterbox")),
    ("YOLO11 araç puanı yalnızca araç sınıflarından", "arac.py",
     "    arac = p[:, [4 + s for s in ARAC_SINIFLARI]].max(axis=1)",
     "    arac = p[:, 4:].max(axis=1)",
     _fn("test_arac", "test_coz11_siniflar_nesne_puani_yok")),
    ("bulucu profilin ön işlemini kullanır", "arac.py",
     "        x, donus = self.profil.hazirla(kirpik)", "        x, donus = on_isle(kirpik)",
     _fn("test_arac", "test_bulucu11_kendi_on_islemini_ve_esik_anahtarini_kullanir")),
    ("YOLO11 eşiği kendi ayar anahtarından", "arac.py",
     "        self.esik = self._esik(profil.esik_anahtari, profil.esik)",
     '        self.esik = self._esik("arac_esik", profil.esik)',
     _fn("test_arac", "test_bulucu11_kendi_on_islemini_ve_esik_anahtarini_kullanir")),
    ("öz sınama profilin kendi altın değeriyle", "arac.py",
     "        if abs(a - self.profil.altin) > ALTIN_PAYI:",
     "        if abs(a - ALTIN_ARAC) > ALTIN_PAYI:",
     _fn("test_arac", "test_oz_sinama11_kendi_altin_degeriyle")),
    ("profil kendi model dosyasını doğrular", "arac.py",
     "    for m in (p.model, SINAMA):", "    for m in (MODEL, SINAMA):",
     _fn("test_arac", "test_yukle_eksik_dosya")),
    # ---- 1.4.0: araç izleme, kapı alanı, kırpma alanı (çokgen) -----------------
    ("ölçülmeyen kare kaçırma saymaz (izci donar)", "takip.py",
     "        if o.araclar is None:\n            return []", "        if o.araclar is None:\n            o = o._replace(araclar=[])",
     _fn("test_takip", "test_olculmeyen_kare_kacirma_saymaz_ve_bostayken_donar")),
    ("girdi yalnızca kapıda DOĞAN araçta", "takip.py",
     '            if (z.kapidan_dogdu and z.koken in ("kapi", "eski") and not z.giris_karari',
     '            if (True and not z.giris_karari',
     _fn("test_takip", "test_otopark_icinde_hareket_sayilmaz")),
    ("kapıdan çıkış payı (sınırda titreme geçiş değil)", "takip.py",
     "z.disari_kare = z.disari_kare + 1 if mesafe <= -payi else 0",
     "z.disari_kare = z.disari_kare + 1 if mesafe < 0 else 0",
     _fn("test_takip", "test_kapi_sinirinda_titreme_gecis_sayilmaz")),
    ("çıktı yalnızca KAPIDA kaybolunca", "takip.py",
     "        if (ic and not z.duruyor and z.disarida_bulundu and not z.cikis_karari",
     "        if (not z.duruyor and z.disarida_bulundu and not z.cikis_karari",
     _fn("test_takip", "test_otoparkta_hareketliyken_kaybolan_cikis_sayilmaz")),
    ("duruyorken kaybolan araç çıkmış sayılmaz", "takip.py",
     "        if (ic and not z.duruyor and z.disarida_bulundu and not z.cikis_karari",
     "        if (ic and z.disarida_bulundu and not z.cikis_karari",
     _fn("test_takip", "test_kapida_duran_arac_ortulunce_cikis_sayilmaz")),
    ("çıktı yalnızca otoparkta görülmüş araçta", "takip.py",
     "        if (ic and not z.duruyor and z.disarida_bulundu and not z.cikis_karari",
     "        if (ic and not z.duruyor and not z.cikis_karari",
     _fn("test_takip", "test_kapi_sinirinda_dogan_arac_kapida_kaybolunca_cikis_sayilmaz")),
    ("çıktı yalnızca kenara giderken", "takip.py",
     "                and self._kenara_gidiyor(z)):", "                ):",
     _fn("test_takip", "test_kapida_kenardan_uzaklasirken_kaybolan_cikis_sayilmaz")),
    ("açılışta kapıdaki araç 'eski' (personele)", "takip.py",
     '            koken = "eski"', '            koken = "kapi"',
     _fn("test_takip", "test_isinmada_kapida_olan_arac_personele")),
    ("örtülen araç aynı izde sürer (dikiş)", "takip.py",
     '            en_iyi.durum = "izleniyor"\n            return en_iyi',
     '            en_iyi.durum = "izleniyor"\n            en_iyi = None',
     _fn("test_takip", "test_ortulme_dikisi_ayni_izi_surdurur")),
    ("kısa örtülme de dikilir (kayıp olmadan)", "takip.py",
     'gorunmez = z.durum in ("izleniyor", "kayip")',
     'gorunmez = z.durum == "kayip"',
     _fn("test_takip", "test_kisa_ortulme_kayip_olmadan_da_dikilir")),
    ("yavaş dizüstünde büyük adımlar tek iz", "takip.py",
     'gorunmez = z.durum in ("izleniyor", "kayip")',
     'gorunmez = z.durum == "kayip" or (z.durum == "izleniyor" and z.kacirma > 0)',
     _fn("test_takip", "test_yavas_dizustunde_buyuk_adimlar_tek_iz")),
    ("duran aracın izine yanından geçen dikilemez", "takip.py",
     "            if z.duruyor and arac.ortusme(z.kutu, a) < PARK_IOU:", "            if False:",
     _fn("test_takip", "test_duran_aracin_izini_yanindan_gecen_alamaz")),
    ("duran araç yalnızca örtüşerek eşleşir", "takip.py",
     "            if id(z) in kullanilan_iz or z.duruyor:", "            if id(z) in kullanilan_iz:",
     _fn("test_takip", "test_duran_aracin_izini_yanindan_gecen_alamaz")),
    ("duruyor = her karede yerinde (U dönüşü değil)", "takip.py",
     "and all(arac.ortusme(g[1], a) >= DURAN_IOU for g in z.gecmis)",
     "and arac.ortusme(once[1], a) >= DURAN_IOU",
     _fn("test_takip", "test_kapidan_girip_geri_donen_sayilmaz")),
    ("görünmez aracın yeri hızıyla tahmin edilir", "takip.py",
     "gecen = 0.0 if z.duruyor else min(o.mono - z.son_mono, DIKIS_TAHMIN_SN)", "gecen = 0.0",
     _fn("test_takip", "test_ortulmede_hizla_tahmin_edilen_yerde_dikilir")),
    ("park belleği kararları taşır", "takip.py",
     "                z.giris_karari, z.cikis_karari = giris, cikis",
     "                z.giris_karari, z.cikis_karari = False, False",
     _fn("test_takip", "test_park_bellegi_karar_tekrarlanmaz")),
    ("bir araç bir kez girer", "takip.py",
     "        if z.gecti_mono is not None and not z.giris_karari and z.duruyor:",
     "        if z.gecti_mono is not None and z.duruyor:",
     _fn("test_takip", "test_giris_kapidan_otoparka_gecip_durunca")),
    ("kapısız kipte yeterli yol şartı", "takip.py",
     "        if math.dist(capa, z.bolum_capa) >= EN_AZ_YOL * _kosegen(z.dogum_kutu):",
     "        if math.dist(capa, z.bolum_capa) >= 0:",
     _fn("test_takip", "test_kapisiz_kipirdama_ve_hic_kiprdamayan_sayilmaz")),
    ("iki araca eşit uyan plaka kimseye yazılmaz", "takip.py",
     "                    secilen = False", "                    secilen = sira[0][0]",
     _fn("test_takip", "test_plaka_iki_esit_araca_belirsizse_kimseye_yazilmaz")),
    ("yeni görünüm aracın piksellerinin değişmesini ister", "takip.py",
     "yerel_fark(o.gri, z.gorunum_gri, a, self.en, self.boy) >= self.durgun_esik", "True",
     _fn("test_takip", "test_duran_aracin_kutu_titremesi_hareket_sayilmaz")),
    ("duruyor = pikseller de değişmemiş", "takip.py",
     "and yerel_fark(o.gri, once[2], a, self.en, self.boy) < self.durgun_esik)", "and True)",
     _fn("test_takip", "test_surunen_arac_durmus_sayilmaz")),
    ("araç / kapı bölgesi değişince model karesi", "takip.py",
     "        if any(yerel_fark(gri, self.son_gri, k, self.en, self.boy) >= self.durgun_esik",
     "        if any(yerel_fark(gri, self.son_gri, k, self.en, self.boy) > 1e9",
     _fn("test_takip", "test_degisti_aracin_ya_da_kapinin_bolgesine_bakar")),
    # 1.4.2: A1'in yerel tetiği takip_ortulme'deki aracı tek başına yakalıyor
    # (degisti orada artık fark etmiyor); kural birim testiyle tutulur — sahip,
    # 2026-11-14: degisti kalır (kare başına ~1 px'ten yavaş sürünen araç).
    ("yavaş kalkan / sürünen aracın değişimi model karesi ister (köprü)", "kopru.py",
     "    return (izci.kare_istiyor() or izci.degisti(gri)",
     "    return (izci.kare_istiyor()",
     _fn("test_kurulum", "test_model_karesi_istegi")),
    ("A1: yerel kıpırtının kuyruğu da model karesi ister", "kopru.py",
     "            or simdi - son_kipirti < KUYRUK_SN or simdi - son_yerel < KUYRUK_SN",
     "            or simdi - son_kipirti < KUYRUK_SN",
     _fn("test_kurulum", "test_model_karesi_istegi")),
    ("araca yazılan plakanın sahipsiz izi bırakılır", "takip.py",
     "        self._plakaci._birak(sahipli, o.mono)", "        pass",
     _fn("test_takip", "test_araca_ait_plaka_izi_duser")),
    ("izleme karesini iki model birlikte bitirir", "okuma.py",
     "            return all(k.bos() for k in kuyruklar)", "            return kuyruklar[0].bos()",
     _fn("test_okuma", "test_isci_kare_iki_modelin_sonucunu_birlestirir")),
    ("bulucu hatası izleme karesini bitirir", "okuma.py",
     '                        self._parca_bitti(is_.kare.no, "arac", olcum)', "                        pass",
     _fn("test_okuma", "test_isci_kare_model_hatasi_birlesimi_bitirir")),
    ("bir izde iki emin plaka: personele", "okuma.py",
     "    if len(k.eminler) >= 2:", "    if False:",
     _fn("test_okuma", "test_iz_karari")),
    ("izin zamanı olayın anı", "okuma.py",
     '        return [Gonderim("PLAKA", e.metin, None, None, olay_zamani,',
     '        return [Gonderim("PLAKA", e.metin, None, None, e.zaman,',
     _fn("test_okuma", "test_iz_karari")),
    ("izde 60 sn kuralı", "okuma.py",
     "        if _yeni_gitti(e.metin, son_gonderilen, simdi):", "        if False:",
     _fn("test_okuma", "test_iz_karari")),
    ("şeridin yönüne ters olay gönderilmez", "kopru.py",
     '        if (YON == "GIRIS" and olay.tur == "CIKTI") or (',
     '        if (False) or (',
     _senaryo("takip_giris_seridi")),
    ("bulucu bozulunca 1.3.4 kuralına dönülür", "kopru.py",
     "        if izleme and isci.arac_esikleri() is None:", "        if False:",
     _senaryo("takip_bulucu_bozuldu")),
    ("kırpma alanının kenarı plakayı keser", "plaka.py",
     "        return self.disarida_px(k.x1 - px, k.y1 - py, k.x2 + px, k.y2 + py) == 0",
     "        return self.disarida_px(k.x1, k.y1, k.x2, k.y2) == 0",
     _fn("test_plaka", "test_alan_maskesi_l_sekli_eski_haric_kuraliyla_ayni")),
    ("kırpma alanının dışındaki plaka düşer", "plaka.py",
     "        return haric.oran(k)", "        return 0.0",
     _fn("test_okuma", "test_kirpma_alaninin_kenarindaki_plaka_okunmaz")),
    ("kırpma alanının dışındaki araç düşer", "arac.py",
     "        tut = haric.oranlar(kutular) <= HARIC_DUSUR", "        tut = haric.oranlar(kutular) <= 1.0",
     _fn("test_arac", "test_kirpma_alani_cokgen")),
    ("kendini kesen alan reddedilir", "plaka.py",
     '                raise ValueError("alanın kenarları birbirini kesiyor — köşeleri sırayla tıklayın")',
     "                pass",
     _fn("test_plaka", "test_cokgen_coz")),
    ("alanın dışı griye boyanır", "kopru.py",
     "        cv2.copyTo(kaynak, _alan_dis_maskesi(kaynak.shape, frame.shape, kutu, alan), parca)",
     "        parca[...] = kaynak",
     _fn("test_kurulum", "test_kirp_maskeli_cokgen")),
    ("kırpma köşeleri kenara yapışır", "kirpma_sunucu.py",
     "        alan = _cokgen_ham([list(n) for n in _yapistir(sikis, 0, 0, en, boy)])",
     "        alan = _cokgen_ham([list(n) for n in sikis])",
     _fn("test_kurulum", "test_kirpma_sunucusu_alan_ve_kapi")),
    ("kırpmayla kesişmeyen kapı alanı reddedilir", "kirpma_sunucu.py",
     "        if not k.any():", "        if False:",
     _fn("test_kurulum", "test_kirpma_sunucusu_alan_ve_kapi")),
    ("yeniden kurulum eski kapı alanını siler", "kurulum.py",
     '    ayar["KAPI_ALANI"] = plaka.cokgen_metni(kapi) if kapi else ""', "    pass",
     _fn("test_kurulum", "test_kirpma_alani_ve_kapi_ayara_yazilir_ve_yeniden_kurulumda_silinir")),
    ("alan çizilince eski kutu boşaltılır", "kurulum.py",
     '        ayar["KIRPMA"] = ""\n        print(f"  ✓ Kırpma alanı',
     '        print(f"  ✓ Kırpma alanı',
     _fn("test_kurulum", "test_kirpma_alani_ve_kapi_ayara_yazilir_ve_yeniden_kurulumda_silinir")),
    # ---- 1.4.1: kapıda görülmeyen araç (hız kuralı), karanlıkta plaka ↔ araç -----
    ("hız kuralı: girişte geri yol kapıdan geçmeli", "takip.py",
     "        return self._yol_kapiya_degiyor(geri, a, pay)", "        return True",
     _fn("test_takip", "test_hizli_otopark_ici_sayilmaz")),
    ("hız kuralı: ağır adım hızlı geçiş değil", "takip.py",
     "        if math.dist(a, b) < pay or self._kapi_mesafe(b) >= self._kapi_mesafe(a):",
     "        if self._kapi_mesafe(b) >= self._kapi_mesafe(a):",
     _fn("test_takip", "test_kapi_yaninda_agir_kalkan_giris_sayilmaz")),
    ("hız kuralı yalnızca ilk iki görülmede", "takip.py",
     "            if z.gorulme == 2 and self._kapidan_geldi_mi(z):",
     "            if self._kapidan_geldi_mi(z):",
     _fn("test_takip", "test_kapida_kalkan_park_arac_girdi_sayilmaz")),
    ("hız kuralı: iki görülmede kapıdan çıkış doğduğu an", "takip.py",
     "                    z.gecti_mono, z.gecti_zaman = z.dogum_mono, z.dogum_zaman",
     "                    pass",
     _fn("test_takip", "test_hizli_giris_iki_kez_gorulup_kaybolan")),
    ("hız kuralı: çıkışta ileri yol kapıya varmalı", "takip.py",
     "        return self._yol_kapiya_degiyor(b, ileri, pay)", "        return True",
     _fn("test_takip", "test_kapiya_giderken_otoparkta_kaybolan_cikis_sayilmaz")),
    ("karanlıkta: plaka izi araca devredilir", "takip.py",
     "                        if eski:", "                        if False:",
     _fn("test_takip", "test_karanlik_arac_plakayla_girip_isikta_gorunur")),
    ("karanlıkta: plaka gövdesi görünmeyen aracı yaşatır", "takip.py",
     "                    self._plakayla_ilerlet(z, k, o, olaylar)", "                    pass",
     _fn("test_takip", "test_isikta_gorunen_arac_karanlikta_plakayla_cikar")),
    ("karanlıkta: geçen plaka duran aracı sürükleyemez", "takip.py",
     "        if z.plaka_ofset is None or z.plaka_kilit:", "        if z.plaka_ofset is None:",
     _fn("test_takip", "test_karanlikta_yavas_gecen_plaka_park_araci_suruklemez")),
    ("karanlıkta: AĞIR geçen plaka da duran aracı sürükleyemez", "takip.py",
     "        if z.duruyor:\n            z.plaka_kilit = True",
     "        if False:\n            z.plaka_kilit = True",
     _fn("test_takip", "test_karanlikta_yavas_gecen_plaka_park_araci_suruklemez")),
    ("devir: plaka izi aracın kutusunda olmalı", "takip.py",
     "                                and self._kutuda(_merkez(p.tahmin(o.mono)), z.kutu)]",
     "                                ]",
     _fn("test_takip", "test_yeni_gorunen_arac_kutusu_disindaki_plaka_izini_devralmaz")),
    ("hız kuralı: boşta beklemeden sonra en çok 1.5 adım geri", "takip.py",
     "        g = min(z.onceki_bosluk, ADIM_KAT * dt, TAHMIN_SN)",
     "        g = min(z.onceki_bosluk, TAHMIN_SN)",
     _fn("test_takip", "test_bosta_bekleme_sonrasi_hiz_kurali_fazla_geriye_bakmaz")),
    ("hız kuralı: plaka izini devralan araçta değil", "takip.py",
     '        if (z.koken != "yard" or z.kapidan_dogdu or z.giris_karari or z.devraldi',
     '        if (z.koken != "yard" or z.kapidan_dogdu or z.giris_karari',
     _fn("test_takip", "test_otoparkta_plakasi_izlenen_arac_isikta_kalkinca_girdi_sayilmaz")),
    ("tek kare: yalnızca gerçekten hareketli araç", "takip.py",
     '        if (self.kaynak == "arac" and z.gorulme == 1 and z.dogum_hareketli',
     '        if (self.kaynak == "arac" and z.gorulme == 1',
     _fn("test_takip", "test_tek_karede_kipirdamayan_park_araci_sayilmaz")),
    ("tek kare: yalnızca araç izinde (plaka izinde değil)", "takip.py",
     '        if (self.kaynak == "arac" and z.gorulme == 1 and z.dogum_hareketli',
     "        if (z.gorulme == 1 and z.dogum_hareketli",
     _fn("test_takip", "test_tek_kare_plaka_izinde_yok_giren_araca_ikinci_kart_olmaz")),
    ("tek kare: devralınan kararı tekrarlamaz", "takip.py",
     "                and not (z.devraldi or z.giris_karari or z.cikis_karari\n"
     "                         or z.gecti_mono is not None)\n",
     "",
     _fn("test_takip", "test_tek_kare_devralinan_karari_tekrarlamaz")),
    ("tek kare: önünden geçilen araç hareketli sayılmaz", "takip.py",
     "            and not any(b is not a and _kesisim(a, b) > TEK_KARE_ORTUSME * _alan(a)",
     "            and not any(False",
     _fn("test_takip", "test_tek_kare_onunden_gecilen_park_araci_sayilmaz")),
    ("tek kare: yalnızca kapının yakınında", "takip.py",
     "                and self._kapi_mesafe(capa) >= -_kosegen(z.kutu)):", "                ):",
     _fn("test_takip", "test_tek_karede_otoparkta_gorulen_sayilmaz")),
    ("tek kare personele gider (plaka emin olsa da)", "okuma.py",
     '    return tur in ("ESKI_GIRDI", "TEK_KARE", "KAPIDA_KAYBOLDU")',
     '    return tur in ("ESKI_GIRDI", "KAPIDA_KAYBOLDU")',
     _fn("test_okuma", "test_iz_personele_olaylari")),
    ("köprü izleme olayının personele kararını okumadan alır", "kopru.py",
     "            arac_gecis_esik=okuma.iz_arac_esigi(olay.tur, bulucu.esik, bulucu.gecis_esik,\n"
     "                                                komsu=olay.iz.dogumda_komsu),\n"
     "            personele=okuma.iz_personele(olay.tur))",
     "            arac_gecis_esik=okuma.iz_arac_esigi(olay.tur, bulucu.esik, bulucu.gecis_esik,\n"
     "                                                komsu=olay.iz.dogumda_komsu),\n"
     "            personele=False)",
     _senaryo("takip_baslangicta_kapida")),
    ("kapıdan geçen plakasız araç 0.35'ten personele", "okuma.py",
     '    return arac_esik if tur in ("GIRDI", "CIKTI", "KAPIDA_KAYBOLDU", "TEK_KARE") else arac_gecis_esik',
     "    return arac_gecis_esik",
     _fn("test_okuma", "test_iz_arac_esigi_kapidan_gecen_plakasiz_arac")),
    ("köprü kapı geçişinde 0.35 eşiğini kullanır", "kopru.py",
     "            arac_gecis_esik=okuma.iz_arac_esigi(olay.tur, bulucu.esik, bulucu.gecis_esik,\n"
     "                                                komsu=olay.iz.dogumda_komsu),\n"
     "            personele=okuma.iz_personele(olay.tur))",
     "            arac_gecis_esik=bulucu.gecis_esik,\n"
     "            personele=okuma.iz_personele(olay.tur))",
     _senaryo("takip_plakasiz_zayif")),
    # ---- 1.4.2: grafik işlemcisi, eşikler modelin -------------------------------
    ("köprü kapı kararında YÜKLENEN bulucunun eşiğini kullanır", "kopru.py",
     "            arac_gecis_esik=okuma.iz_arac_esigi(olay.tur, bulucu.esik, bulucu.gecis_esik,\n"
     "                                                komsu=olay.iz.dogumda_komsu),\n"
     "            personele=okuma.iz_personele(olay.tur))",
     "            arac_gecis_esik=okuma.iz_arac_esigi(olay.tur, 0.35, 0.60,\n"
     "                                                komsu=olay.iz.dogumda_komsu),\n"
     "            personele=okuma.iz_personele(olay.tur))",
     _senaryo("takip_gpu_esikleri")),
    ("izci bulucu tiny'ye geçince yeni doğum eşiğini alır", "kopru.py",
     "            izci.dogum_esik = bulucu.esik", "            pass",
     _senaryo("takip_gpu_tiny_ye_gecti")),
    ("GPU dolgu satırı plaka sayılmaz", "plaka.py",
     "        if satir[0] < 0:", "        if False:",
     _fn("test_plaka", "test_kutu_gpu_dolgu_satirlari_atlanir")),
    ("okuyucu GPU'da f32", "plaka.py",
     "            okuyucu = hiz.oturum(o_yol, hassas=True, sekiller=OKUYUCU_SEKILLERI)",
     "            okuyucu = hiz.oturum(o_yol, hassas=False, sekiller=OKUYUCU_SEKILLERI)",
     _fn("test_plaka", "test_yukle_gpu_okuyucu_tam_hassas")),
    ("GPU çağrısı bozulursa aynı çağrı işlemcide", "hizlandirici.py",
     "        return self._cpu.run(adlar, girdiler)",
     '        raise plaka.HizlandiriciHatasi("işlemciye geçilmedi")',
     _fn("test_hizlandirici", "test_yedekli_oturum_gpu_hatasinda_isleme_gecer")),
    ("araç bulucu GPU bozulursa işlemcideki tiny'ye geçer", "arac.py",
     "        self._yedege_gec(son)", "        raise son",
     _fn("test_arac", "test_gpu_hatasinda_islemcideki_tiny_ye_gecer")),
    # ---- 1.4.2: GPU için savaş (sahibin isteği, 2026-11-13) -----------------------
    ("plaka öz sınaması GPU'da yedeksiz (işlemciye kaçamaz)", "plaka.py",
     "            bulucu = hiz.oturum(b_yol, hassas=False)",
     '            bulucu = hiz.yedekli(hiz.oturum(b_yol, hassas=False), '
     'lambda: ort_oturumu(b_yol, iplik), "plaka bulucu")',
     _fn("test_hizlandirici", "test_gpu_oz_sinamasi_isleme_kacamaz")),
    ("araç öz sınaması GPU'da yedeksiz (işlemciye kaçamaz)", "arac.py",
     "    b = AracBulucu(oturum, ayar, d, profil=p)",
     "    b = AracBulucu(oturum, ayar, d, profil=p, yedek=yedek)",
     _fn("test_hizlandirici", "test_gpu_oz_sinamasi_isleme_kacamaz")),
    ("plaka oturumu GPU'yu 3 kez dener", "hizlandirici.py",
     "            for _ in range(DENEME):", "            for _ in range(1):",
     _fn("test_hizlandirici", "test_yedekli_oturum_iki_hatadan_sonra_gpu_da_kalir")),
    ("araç bulucu GPU'yu 3 kez dener", "arac.py",
     "        for _ in range(plaka.GPU_DENEME):", "        for _ in range(1):",
     _fn("test_arac", "test_gpu_iki_hatadan_sonra_gpu_da_kalir")),
    ("geri dönüş 30 sn'de bir dener (daha sık değil)", "hizlandirici.py",
     "        if self._is or simdi - self._son_deneme < self.dene_sn:", "        if self._is:",
     _fn("test_hizlandirici", "test_geri_donus_30_sn_de_bir_dener_ve_doner")),
    ("geri dönüşte aynı anda tek iş", "hizlandirici.py",
     "        if self._is or simdi - self._son_deneme < self.dene_sn:",
     "        if simdi - self._son_deneme < self.dene_sn:",
     _fn("test_hizlandirici", "test_geri_donus_ayni_anda_tek_is_ve_cokunce_yeniden")),
    ("çöken geri dönüş işi sonrakini engellemez", "hizlandirici.py",
     "        finally:\n            self._is = False", "        finally:\n            pass",
     _fn("test_hizlandirici", "test_geri_donus_ayni_anda_tek_is_ve_cokunce_yeniden")),
    ("plaka oturumu yayımlanan GPU'yu kendi çağrısında devralır", "hizlandirici.py",
     "        if yeni is not None:\n            self._yeni = None\n            self._gpu = yeni",
     "        if False:\n            pass",
     _fn("test_hizlandirici", "test_geri_donus_30_sn_de_bir_dener_ve_doner")),
    ("araç bulucu yayımlanan GPU'yu kendi karesinde devralır", "arac.py",
     "        self._uygula()\n", "",
     _fn("test_hizlandirici", "test_bulucu_islemciden_baslayip_gpu_ya_doner_ve_yine_duser")),
    ("açılışta GPU yoksa işlemci oturumları geri dönebilsin diye sarılır", "hizlandirici.py",
     "    if gpu_hata is not None and isinstance(p, plaka.Plakaci):",
     "    if False:",
     _fn("test_hizlandirici", "test_geri_donus_gercek_modellerle_acilista_gpu_yoktu")),
    ("yeniden başlatma için 10 dk işlemcide", "hizlandirici.py",
     "        if self._saat() - self._cpu_baslangic < self.yeniden_sn:", "        if False:",
     _fn("test_hizlandirici", "test_geri_donus_yeniden_baslatma_kosulu_saatte_bir")),
    ("GPU için yeniden başlatma saatte en çok bir", "hizlandirici.py",
     "        return self._duvar() - self._son_yeniden() >= self.aralik_sn", "        return True",
     _fn("test_hizlandirici", "test_geri_donus_yeniden_baslatma_kosulu_saatte_bir")),
    ("izlemede GPU yeniden başlatması yalnızca sakin anda", "kopru.py",
     "            gpu_yeniden_baslat_belki(not izci.kare_istiyor() and isci.ikisi_bos()\n"
     "                                     and simdi - son_kipirti >= GPU_SAKIN_SN)",
     "            gpu_yeniden_baslat_belki(True)",
     _senaryo("takip_gpu_kayip_yeniden_baslat")),
    ("geçiş kuralında GPU yeniden başlatması yalnızca sakin anda", "kopru.py",
     "        gpu_yeniden_baslat_belki(gecis is None and isci.ikisi_bos()\n"
     "                                 and simdi - son_kipirti >= GPU_SAKIN_SN)",
     "        gpu_yeniden_baslat_belki(True)",
     _senaryo("gpu_kayip_gecis_kurali")),
    ("geçiş kuralında sakinlik gönderimden sonra sıfırlanan saate bakmaz", "kopru.py",
     "        if d >= DURGUN_ESIGI:\n            son_kipirti = simdi\n        gpu_yeniden",
     "        gpu_yeniden",
     _senaryo("gpu_kayip_gecis_kurali")),
    ("Durum: 1 saatten uzun işlemcide uyarılır", "durum.py",
     "    if sure < ISLEMCI_UYARI_SN:", "    if True:",
     _fn("test_kurulum", "test_durum_uzun_sure_islemcide_uyarir")),
    ("Durum: GPU için yeniden başlatma işlemci süresini sıfırlamaz", "durum.py",
     "            if not son_yeniden:", "            if True:",
     _fn("test_kurulum", "test_durum_uzun_sure_islemcide_uyarir")),
    ("GPU'da öz sınama tutmazsa hepsi işlemciye", "hizlandirici.py",
     "        except (plaka.HizlandiriciHatasi, plaka.PlakaHatasi) as e:",
     "        except plaka.HizlandiriciHatasi as e:",
     _fn("test_hizlandirici", "test_kume_gpu_oz_sinamasi_tutmazsa_hepsi_islemciye")),
    ("HIZLANDIRICI=CPU iken GPU denenmez", "hizlandirici.py",
     '    if ayar.get("hizlandirici", "GPU") == "GPU":', "    if True:",
     _fn("test_hizlandirici", "test_kume_cpu_istenirse_gpu_denenmez")),
    ("ölçülmemiş YOLO11s 'otomatik'te açılmaz", "hizlandirici.py",
     "    return arac.YOLOX_TINY if arac.YOLO11S.yer_tutucu else arac.YOLO11S",
     "    return arac.YOLO11S",
     _fn("test_hizlandirici", "test_arac_profili")),
    ("kalp satırı bırakılan GPU'yu söyler", "hizlandirici.py",
     "            plaka.GPU_BIRAKILANLAR.append(self.ad)", "            pass",
     _fn("test_hizlandirici", "test_kalp_etiketi_birakilan_gpu_yu_soyler")),
    ("öz sınama resmi Türkçe harfli klasörde de okunur", "arac.py",
     "        img = resim_oku(os.path.join(self._dizin, SINAMA.dosya))",
     "        img = cv2.imread(os.path.join(self._dizin, SINAMA.dosya))",
     _fn("test_arac", "test_turkce_harfli_klasorde_oz_sinama")),
    ("derlemede GPU varken .exe de GPU'yu kullanmalı", "paketle.py",
     '    if gpu_var and "Grafik işlemcisi hazır" not in cikti:', "    if False:",
     _fn("test_kurulum", "test_paket_derleme_sinamasi_gpu")),
    ("NPU pakete girmez", "paketle.py",
     'OV_DISLA = ("openvino_intel_npu", "_frontend.lib", "openvino_gguf_frontend",',
     'OV_DISLA = ("_frontend.lib", "openvino_gguf_frontend",',
     _fn("test_kurulum", "test_paket_openvino_secimi")),
    ("derleme komutu kısa kalır (dosyalar kancada)", "paketle.py",
     '    komut += ["--additional-hooks-dir", KANCA_DIZINI, "--hidden-import", "openvino",',
     '    komut += ["--add-binary", "C:/sp/openvino/libs/x.dll;openvino/libs"] * 400\n'
     '    komut += ["--additional-hooks-dir", KANCA_DIZINI, "--hidden-import", "openvino",',
     _fn("test_kurulum", "test_paket_openvino_secimi")),
    ("Durum: tek kare satırı kameranın çalıştığını gösterir", "durum.py",
     "gunluk.KAPIDA_BEKLIYOR_ISARETI, gunluk.TEK_KARE_ISARETI,",
     "gunluk.KAPIDA_BEKLIYOR_ISARETI,",
     _fn("test_kurulum", "test_durum_arac_izleme_satiri")),
    # ---- 1.4.1: çok karede birleştirme ---------------------------------------
    ("birleşik: en az 3 farklı görünüm", "plaka.py",
     "            if len(gorunum) < BIRLESIK_GORUNUM or tepe < BIRLESIK_TEPE:",
     "            if len(gorunum) < 2 or tepe < BIRLESIK_TEPE:",
     _fn("test_plaka", "test_birlesik_iki_gorunum_yetmez")),
    ("birleşik: bir kırpıntı ≥ 0.90", "plaka.py",
     "            if len(gorunum) < BIRLESIK_GORUNUM or tepe < BIRLESIK_TEPE:",
     "            if len(gorunum) < BIRLESIK_GORUNUM:",
     _fn("test_plaka", "test_birlesik_hic_net_kirpinti_yoksa_olmaz")),
    ("birleşik: bir karakter yakın rakip varsa olmaz", "plaka.py",
     "            if any(r != m and bir_fark(r, m) for r in rakipler):",
     "            if False:",
     _fn("test_plaka", "test_birlesik_yakin_baska_metin_varsa_olmaz")),
    ("birleşik: kapalıyken bugünkü kural", "plaka.py",
     "        if self.birlesik:\n            # 1.4.1:",
     "        if True:\n            # 1.4.1:",
     _fn("test_plaka", "test_birlesik_kapaliyken_bugunku_kural")),
    ("birleşik: izde başka plakanın oyu varsa olmaz", "plaka.py",
     "            if any(r != m for r in set(self._okumalar) | set(self._yarim)) or any(",
     "            if False or any(",
     _fn("test_plaka", "test_birlesik_izde_baska_plaka_varsa_olmaz")),
    ("birleşik: izde başka plakanın ≥ 0.50 tahmini varsa olmaz", "plaka.py",
     "                    r != m and g >= YARIM_ESIK for r, g in self._tahminler.items()):",
     "                    False for r, g in self._tahminler.items()):",
     _fn("test_plaka", "test_birlesik_izde_baska_plaka_varsa_olmaz")),
    ("plaka izinde birleştirme kapalı", "takip.py",
     "            gecis.oylama.birlesik = False", "            pass",
     _fn("test_takip", "test_plaka_izinde_birlestirme_kapali")),
    ("birleşik plakanın kanıtı okunduğu kare", "okuma.py",
     "                        gecis.en_iyi[okunan[0][0]] = (dusuk, kirpik)",
     "                        pass",
     _fn("test_okuma", "test_plakalari_yaz_yarim_oy_ve_birlesik_karar")),
    ("yarım oy: iki kırpıntı ≥ 0.50", "okuma.py",
     "                        and min(okunan[0][1], okunan[1][1]) >= plaka.YARIM_ESIK):",
     "                        and min(okunan[0][1], okunan[1][1]) >= 0.0):",
     _fn("test_okuma", "test_plakalari_yaz_yarim_oy_ve_birlesik_karar")),
    ("yarım oy: iki kırpıntı AYNI metin", "okuma.py",
     "                if (len(okunan) == 2 and okunan[0][0] == okunan[1][0]",
     "                if (len(okunan) == 2",
     _fn("test_okuma", "test_plakalari_yaz_yarim_oy_ve_birlesik_karar")),
    ("iki kırpıntının metinleri rakip olarak kaydedilir", "okuma.py",
     "            gecis.oylama.gorulen([m for m, _ in okunan])",
     "            pass",
     _fn("test_okuma", "test_plakalari_yaz_yarim_oy_ve_birlesik_karar")),
    ("köprü izlemede birleştirmeyi açar", "kopru.py",
     '                                           plaka.Oylama(tek_esik=p_ayar["tek_esik"],\n'
     '                                                        birlesik=p_ayar["birlesik"])),',
     '                                           plaka.Oylama(tek_esik=p_ayar["tek_esik"],\n'
     "                                                        birlesik=False)),",
     _senaryo("takip_birlesik")),
    ("--plaka: 130 px altı plakada yakınlaştırma önerir", "okuma.py",
     "    if orta < PLAKA_EN_AZ_PX:", "    if False:",
     _fn("test_okuma", "test_plaka_genisligi_ve_ozet")),
    ("--plaka: plaka genişliği özeti yazılır", "kopru.py",
     "    boy_ozeti = okuma.plaka_boyu_ozeti(genislikler)\n", "    boy_ozeti = None\n",
     _fn("test_kurulum", "test_plaka_kipi_emin_okuma")),
    ("kayıtta 'kapıda görülmedi'", "kopru.py",
     '        kapida = f", {gunluk.KAPIDA_GORULMEDI_ISARETI}" if olay.iz.kapida_gorulmedi else ""',
     '        kapida = ""',
     _senaryo("takip_hizli_giris")),
    # ---- 1.4.2 (A1 / A2): sahada 11.11 iz bırakmadan kaybolan beş araç ------------
    ("A2: kapıda doğup kapıda kaybolan araç personele", "takip.py",
     "            elif self._kapida_kayboldu_mu(z):\n"
     '                olaylar.append(Olay("KAPIDA_KAYBOLDU", z, z.son_zaman))\n',
     "",
     _fn("test_takip", "test_kapida_dogup_kapida_kaybolan_arac_personele")),
    ("A2: kapı payında doğup kapıda kaybolan araç personele", "takip.py",
     "        if (ic and not z.duruyor and not z.disarida_bulundu\n"
     "                and self._kapida_kayboldu_mu(z)):",
     "        if (False\n"
     "                and self._kapida_kayboldu_mu(z)):",
     _fn("test_takip", "test_kapi_payinda_dogup_kapida_kaybolan_arac_personele")),
    ("A2: kapıda kaybolan: en az iki karede görülmüş", "takip.py",
     '        return (self.kaynak == "arac" and z.gorulme >= 2',
     '        return (self.kaynak == "arac" and z.gorulme >= 1',
     _fn("test_takip", "test_kapida_tek_karede_kipirdamayan_personele_gitmez_kayda_yazilir")),
    ("A2: kapıda kaybolan: yalnızca araç izinde", "takip.py",
     '        return (self.kaynak == "arac" and z.gorulme >= 2',
     "        return (z.gorulme >= 2",
     _fn("test_takip", "test_plaka_izi_kapida_kaybolunca_personele_gitmez")),
    ("A2: kararsız biten iz kayda geçer", "takip.py",
     '        self._kararsizlar.append((z, "kapı" if ic else "otopark"))',
     "        pass",
     _fn("test_takip", "test_kararsiz_biten_iz_kayda_yazilir")),
    ("A2: duran araç kararsız sayılmaz (park belleği)", "takip.py",
     '        if (self.kaynak != "arac" or z.duruyor or z.olay_sayisi',
     '        if (self.kaynak != "arac" or z.olay_sayisi',
     _fn("test_takip", "test_kapida_duran_arac_kaybolunca_personele_gitmez")),
    ("A2: kopmada hareketli iz kayda geçer", "takip.py",
     '            elif z.durum != "bitti" and not z.duruyor:\n'
     "                # 1.4.2 (A2): hareket hâlindeyken kopan iz de kayda geçer.\n"
     "                self._kararsiz(z)\n",
     "",
     _fn("test_takip", "test_kopmada_hareketli_kararsiz_iz_kayda_yazilir")),
    ("A2: kapıda kaybolan araç personele (plaka emin olsa da)", "okuma.py",
     '    return tur in ("ESKI_GIRDI", "TEK_KARE", "KAPIDA_KAYBOLDU")',
     '    return tur in ("ESKI_GIRDI", "TEK_KARE")',
     _fn("test_okuma", "test_kapida_kaybolan_arac_personele_ve_kapi_esigi")),
    ("A2: kapıda kaybolan plakasız araç 0.35'ten", "okuma.py",
     '    return arac_esik if tur in ("GIRDI", "CIKTI", "KAPIDA_KAYBOLDU", "TEK_KARE") else arac_gecis_esik',
     '    return arac_esik if tur in ("GIRDI", "CIKTI", "TEK_KARE") else arac_gecis_esik',
     _fn("test_okuma", "test_kapida_kaybolan_arac_personele_ve_kapi_esigi")),
    ("A3: tek karede görülen plakasız araç doğum eşiğinden", "okuma.py",
     '    return arac_esik if tur in ("GIRDI", "CIKTI", "KAPIDA_KAYBOLDU", "TEK_KARE") else arac_gecis_esik',
     '    return arac_esik if tur in ("GIRDI", "CIKTI", "KAPIDA_KAYBOLDU") else arac_gecis_esik',
     _fn("test_okuma", "test_tek_kare_plakasiz_arac_dogum_esiginden")),
    ("A2: köprü kararsız izleri kayda yazar", "kopru.py",
     "                iz_gonder(olay, simdi)\n            kararsizlari_yaz()\n",
     "                iz_gonder(olay, simdi)\n",
     _senaryo("takip_kararsiz_iz")),
    ("A2: Durum kapıda kaybolanı sayar", "durum.py",
     '        if f"[i] {gunluk.KAPIDA_KAYBOLDU_ISARETI} (iz" in s:\n            kapida += 1',
     '        if f"[i] {gunluk.KAPIDA_KAYBOLDU_ISARETI} (iz" in s:\n            kapida += 0',
     _fn("test_kurulum", "test_durum_kararsiz_ozet")),
    ("A1: yerel kıpırtı model karesi ister", "kopru.py",
     "            if yerel >= DURGUN_ESIGI:\n                son_yerel = simdi",
     "            if False:\n                son_yerel = simdi",
     _senaryo("takip_gece_hizli_cikis")),
    ("A1: yerel kıpırtı = yamaların EN BÜYÜĞÜ (ortalama değil)", "kopru.py",
     "    return float(cv2.resize(cv2.absdiff(a, b), YAMA_IZGARA, interpolation=cv2.INTER_AREA).max())",
     "    return float(cv2.resize(cv2.absdiff(a, b), YAMA_IZGARA, interpolation=cv2.INTER_AREA).mean())",
     _fn("test_kurulum", "test_yerel_kipirti_kucuk_hareketi_gorur")),
    ("A3: komşulu tek kare (aracın kuyruğu) 0.60'ta kalır", "okuma.py",
     '    if tur == "TEK_KARE" and komsu:\n        return arac_gecis_esik\n',
     "",
     _fn("test_okuma", "test_tek_kare_komsulu_kuyruk_eski_esikte")),
    ("A3: yeni iz doğarken komşusuna bakılır", "takip.py",
     "        z.dogumda_komsu = self._komsu_var(a, o.mono)",
     "        z.dogumda_komsu = False",
     _fn("test_takip", "test_kenardan_cikan_aracin_kuyrugu_komsulu_dogar")),
    ("A3: köprü komşu bilgisini eşiğe verir", "kopru.py",
     "                                                komsu=olay.iz.dogumda_komsu),\n"
     "            personele=okuma.iz_personele(olay.tur))",
     "                                                komsu=False),\n"
     "            personele=okuma.iz_personele(olay.tur))",
     _senaryo("takip_kenar_kuyrugu")),
    # ---- 1.4.2 (B5 / B6 / A4): yön ipucu, içerideki araç, kapı dibinde duran ----
    ("B5: giren aracın plakası 'girdi' ipucuyla gider", 'kopru.py',
     '                g = g._replace(hareket=ipucu)',
     '                pass',
     _senaryo("takip_giris")),
    ('B5: ipucu gövdeye yazılır', 'kopru.py',
     '            govde["hareket"] = g.hareket',
     '            pass',
     _senaryo("takip_cikis")),
    ('B5: olay → ipucu eşlemesi doğru yönde', 'kopru.py',
     'HAREKET_IPUCU = {"GIRDI": "GIRDI", "CIKTI": "CIKTI"}',
     'HAREKET_IPUCU = {"GIRDI": "CIKTI", "CIKTI": "GIRDI"}',
     _senaryo("takip_giris")),
    ('B6: içerideki araç yalnızca TEK KAPIDA sorulur', 'kopru.py',
     '            if olay.tur == "ICERIDE" and YON == "ORTAK":',
     '            if olay.tur == "ICERIDE":',
     _senaryo("takip_iceride_giris_seridi")),
    ('B6: tek kapıda içerideki emin plaka sorulur', 'kopru.py',
     '                iceride_sor(olay, simdi)',
     '                pass',
     _senaryo("takip_iceride")),
    ('B6: yalnızca EMİN plaka (personele kart yok)', 'kopru.py',
     '        plakalar = [g._replace(hareket="ICERIDE") for g in gonderimler if g.tur == "PLAKA"]',
     '        plakalar = [g._replace(hareket="ICERIDE") for g in gonderimler]',
     _senaryo("takip_iceride_belirsiz")),
    ('A4: kapıdan görülmeden geçip duran araç girdi', 'takip.py',
     '            elif z.gorulme == 2 and self._durarak_kapidan_geldi_mi(z):',
     '            elif False:',
     _fn("test_takip", "test_kapidan_gorulmeden_girip_duran_arac_girdi")),
    ('A4: açıklanmamış kapı kıpırtısı kaydedilir', 'takip.py',
     '            self._kapi_kipirti_mono = o.mono          # 1.4.2 (A4): kimse açıklamıyor',
     '            pass',
     _fn("test_takip", "test_kapidan_gorulmeden_girip_duran_arac_girdi")),
    ('A4: kapıdaki izlenen aracın kıpırtısı sayılmaz', 'takip.py',
     '        if kapi_kipirdadi and not self._kapida_iz_var():',
     '        if kapi_kipirdadi:',
     _fn("test_takip", "test_kapi_kipirtisini_izlenen_arac_aciklarsa_girdi_degil")),
    ('A4: kapı kıpırtısı en çok KAPI_GECIS_SN önce', 'takip.py',
     '        return z.dogum_mono - z.kapi_kipirti_once <= KAPI_GECIS_SN',
     '        return True',
     _fn("test_takip", "test_kapi_kipirtisi_eskiyse_girdi_degil")),
    ('A4: yalnızca kapının bir araç köşegeni yakınında', 'takip.py',
     '        if mesafe >= -self.kapi_tolerans or -mesafe > _kosegen(z.dogum_kutu):',
     '        if mesafe >= -self.kapi_tolerans:',
     _fn("test_takip", "test_kapidan_gecis_sonrasi_uzakta_duran_dogum_girdi_degil")),
    ('A4: yanında başka iz olan doğumda değil', 'takip.py',
     '                or z.giris_karari or z.devraldi or z.dogumda_komsu or not z.dogum_hareketli',
     '                or z.giris_karari or z.devraldi or not z.dogum_hareketli',
     _fn("test_takip", "test_kapidan_gecis_sonrasi_komsulu_duran_dogum_girdi_degil")),
    # ---- 1.4.2 (E11 / E12): --plaka süresi, --video oynatma ---------------------
    ("E11: --plaka dakikası plaka_testi'ne gider", 'giris.py',
     '        kod = kopru.plaka_testi(yol, sure_sn=dakika * 60.0) or kod',
     '        kod = kopru.plaka_testi(yol) or kod',
     _fn("test_kurulum", "test_giris_plaka_kipi_dakika")),
    ('E11: --plaka dakikası 1-60', 'giris.py',
     '    return n if 1 <= n <= PLAKA_DAKIKA_EN_COK else None',
     '    return n',
     _fn("test_kurulum", "test_giris_plaka_kipi_dakika")),
    ('E12: --video birden çok şeritte şerit ister', 'giris.py',
     '    elif len(kurulu) == 1:',
     '    elif len(kurulu) >= 1:',
     _fn("test_kurulum", "test_giris_video_kipi")),
    ('E12: oynatma ağa hiçbir şey göndermez', 'video.py',
     '    kopru.requests = types.SimpleNamespace(post=post,',
     '    kopru._requests_yok = types.SimpleNamespace(post=post,',
     _senaryo("video_tekrar")),
    ('E12: oynatma gerçek kayıt klasörüne yazmaz', 'video.py',
     '    gunluk.kayit_klasoru = lambda: klasor',
     '    pass',
     _senaryo("video_tekrar")),
]


def _kopya(kok: str) -> str:
    """
    Köprü klasörünün .py dosyaları + modeller (sabit bağlantı) + sunucu
    dosyaları + 1.4.2 PyInstaller kancası (pyi_kancalari/).
    """
    hedef = os.path.join(kok, "tools", "kamera-koprusu")
    os.makedirs(os.path.join(hedef, "modeller"))
    os.makedirs(os.path.join(hedef, "pyi_kancalari"))
    for ad in os.listdir(BURASI):
        if ad.endswith(".py"):
            shutil.copy2(os.path.join(BURASI, ad), hedef)
    for ad in os.listdir(os.path.join(BURASI, "pyi_kancalari")):
        if ad.endswith(".py"):
            shutil.copy2(os.path.join(BURASI, "pyi_kancalari", ad),
                         os.path.join(hedef, "pyi_kancalari"))
    for ad in os.listdir(os.path.join(BURASI, "modeller")):
        kaynak = os.path.join(BURASI, "modeller", ad)
        try:
            os.link(kaynak, os.path.join(hedef, "modeller", ad))
        except OSError:
            shutil.copy2(kaynak, os.path.join(hedef, "modeller", ad))
    for yol in SUNUCU_DOSYALARI:
        h = os.path.join(kok, *yol.split("/"))
        os.makedirs(os.path.dirname(h), exist_ok=True)
        shutil.copy2(os.path.join(DEPO, *yol.split("/")), h)
    return hedef


def _kos(komut: list[str], klasor: str, ortam: dict) -> tuple[int, str]:
    try:
        r = subprocess.run(komut, cwd=klasor, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=600, env=ortam)
    except subprocess.TimeoutExpired:
        return 124, "zaman aşımı"
    return r.returncode, (r.stdout + r.stderr)[-600:]


def main() -> int:
    # Önce: her bozulacak metin dosyada TAM BİR KEZ geçiyor mu?
    eksik = []
    for aciklama, dosya, eski, _yeni, _k in MUTASYONLAR:
        with open(os.path.join(BURASI, dosya), encoding="utf-8") as f:
            n = f.read().count(eski)
        if n != 1:
            eksik.append(f"{dosya}: {n} kez — {aciklama}: {eski!r}")
    if eksik:
        print("Bozulacak metin bulunamadı (kod değişmiş, listeyi güncelleyin):")
        for e in eksik:
            print("  · " + e)
        return 2

    import kalinti
    kok = kalinti.klasor("otopark-mutasyon-")         # tek klasörde; alt süreçler de
    ortam = {**os.environ, "PYTHONIOENCODING": "utf-8",
             "PROGRAMDATA": os.path.join(kok, "programdata")}
    os.makedirs(ortam["PROGRAMDATA"])

    temiz = _kopya(os.path.join(kok, "temiz"))
    print("Bozulmamış kodda her test geçmeli…")
    for komut in {tuple(m[4]) for m in MUTASYONLAR}:
        kod, cikti = _kos(list(komut), temiz, ortam)
        if kod != 0:
            print(f"  ✗ bozulmadan da düşüyor: {' '.join(komut[1:])}\n{cikti}")
            print(f"\nGeçici dosyalar (silinmez): {kok}")
            return 2
    print("  ✓ hepsi geçti\n")

    kacan = []
    for i, (aciklama, dosya, eski, yeni, komut) in enumerate(MUTASYONLAR, 1):
        klasor = _kopya(os.path.join(kok, f"m{i:02d}"))
        yol = os.path.join(klasor, dosya)
        with open(yol, encoding="utf-8", newline="") as f:
            metin = f.read()
        with open(yol, "w", encoding="utf-8", newline="") as f:
            f.write(metin.replace(eski, yeni))
        kod, cikti = _kos(komut, klasor, ortam)
        if kod != 0:
            print(f"  YAKALANDI  {aciklama}")
        else:
            kacan.append(aciklama)
            print(f"  KAÇTI      {aciklama}  ({dosya})")

    print(f"\n{len(MUTASYONLAR) - len(kacan)}/{len(MUTASYONLAR)} yakalandı")
    print(f"Geçici dosyalar (silinmez, elle temizlenir): {kok}")
    return 1 if kacan else 0


if __name__ == "__main__":
    sys.exit(main())
