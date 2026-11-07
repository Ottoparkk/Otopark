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
    ("kutunun tamamını kaplayan hariç alan reddedilir (köprü)", "kopru.py",
     "    if x <= kx and y <= ky and x + w >= kx + kw and y + h >= ky + kh:", "    if False:",
     _fn("test_kurulum", "test_kirpma_metinleri_cozulur")),
    ("kutunun tamamını kaplayan hariç alan reddedilir (sayfa)", "kirpma_sunucu.py",
     "    if haric == kutu:", "    if False:",
     _fn("test_kurulum", "test_kirpma_sunucusu_haric_alan")),
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
    ("duran ama araç görülmeyen gönderilmez", "okuma.py",
     "            arac_yok = (bulucu and arac_durgun is not None",
     "            arac_yok = (False and arac_durgun is not None",
     _fn("test_okuma", "test_karar_duran_ama_arac_gorulmedi_gonderilmez")),
    ("durulan kare ölçülmediyse 1.3.0 kuralı (personele)", "okuma.py",
     "            arac_yok = (bulucu and arac_durgun is not None\n"
     "                        and arac_durgun < arac_esik and not net_arac)",
     "            arac_yok = (bulucu and (arac_durgun if arac_durgun is not None else 0.0)"
     " < arac_esik and not net_arac)",
     _fn("test_okuma", "test_karar_duran_arac_bilinmiyorsa_bugunku_kural")),
    ("geçişten önce orada olan araç bu geçişin aracı değil", "okuma.py",
     "                and arac_arka is not None and arac_arka < arac_esik)", "                )",
     _fn("test_okuma", "test_karar_gecen_arac_her_kosul_gerekli")),
    ("durmadan geçen plakasız araç personele", "okuma.py",
     "        elif not durdu and arac_boyu and not arka_kutulu and net_arac:", "        elif False:",
     _senaryo("plakasiz_gecen")),
    ("araç bulucu hatası plaka okumayı durdurmaz", "okuma.py",
     "        except Exception as e:  # noqa: BLE001 — bulucu okuyucuyu öldürmesin",
     "        except ZeroDivisionError as e:",
     _fn("test_okuma", "test_isci_arac_hatasi_okumayi_durdurmaz")),
    ("karar kare süresine göre bekler", "okuma.py",
     "        sure = taban if ort is None else max(taban, BEKLE_KAT * ort)", "        sure = taban",
     _fn("test_okuma", "test_isci_bekleme_suresi_kare_suresine_uyar")),
    ("araç bulucu girdisi BGR, ham (legacy değil)", "arac.py",
     "    return np.ascontiguousarray(tuval.transpose(2, 0, 1)[None], dtype=np.float32), r",
     "    return np.ascontiguousarray(tuval[:, :, ::-1].transpose(2, 0, 1)[None], "
     "dtype=np.float32), r",
     _fn("test_arac", "test_on_isle_bgr_ham_sol_ust")),
    ("kesilen köşedeki araç sayılmaz", "arac.py",
     "        tut = _haric_orani(kutular, haric) <= HARIC_DUSUR",
     "        tut = _haric_orani(kutular, haric) <= 1.0",
     _fn("test_arac", "test_skorla_kesilen_koseyi_atlar")),
    ("araç modeli özeti tutmazsa açılmaz", "arac.py",
     "        if plaka.sha256_dosya(yol) != m.sha256:", "        if False:",
     _fn("test_arac", "test_yukle_bozuk_dosya")),
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
