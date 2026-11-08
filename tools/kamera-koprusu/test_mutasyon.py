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
    ("yavaş kalkan aracın çıkışı kaçmaz (köprü)", "kopru.py",
     "            istek = (izci.kare_istiyor() or izci.degisti(gri)",
     "            istek = (izci.kare_istiyor()",
     _senaryo("takip_ortulme")),
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
]


def _kopya(kok: str) -> str:
    """Köprü klasörünün .py dosyaları + modeller (sabit bağlantı) + sunucu dosyaları."""
    hedef = os.path.join(kok, "tools", "kamera-koprusu")
    os.makedirs(os.path.join(hedef, "modeller"))
    for ad in os.listdir(BURASI):
        if ad.endswith(".py"):
            shutil.copy2(os.path.join(BURASI, ad), hedef)
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

    kok = tempfile.mkdtemp(prefix="otopark-mutasyon-")
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
