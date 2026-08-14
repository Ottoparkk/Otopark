/**
 * Row and RPC types, mirroring supabase/migrations/001_schema.sql exactly.
 *
 * Money is `integer` in Postgres and therefore a plain JS number here, in
 * KURUŞ. There is no float arithmetic anywhere in src/ — see lib/money.ts.
 * Timestamps arrive as ISO strings; dates as 'YYYY-MM-DD'.
 */

/* ------------------------------------------------------------------ enums */

export type Rol = 'YONETICI' | 'PERSONEL'
export type KullaniciDurum = 'PENDING' | 'ACTIVE' | 'DISABLED'
export type AracTipi = 'MOTOSIKLET' | 'OTOMOBIL' | 'MINIBUS' | 'KAMYONET'
export type BiletDurum = 'ACIK' | 'KAPALI' | 'IPTAL'
export type OdemeYontemi = 'NAKIT' | 'KREDI_KARTI' | 'HAVALE'
export type Kaynak = 'MOBIL' | 'KAMERA' | 'MANUEL'
export type ParkYeriTip = 'NORMAL' | 'ENGELLI' | 'SARJ'
export type AbonmanDurum = 'AKTIF' | 'DOLDU' | 'IPTAL'
export type IstisnaTur = 'GELECEK' | 'BAYAT' | 'ACIK_BILET_YOK' | 'COKLU_ESLESME'
export type HesapDurum = 'AKTIF' | 'PASIF'
export type PuanHareketTur = 'KAZANIM' | 'KULLANIM' | 'IPTAL' | 'DUZELTME'
export type KasaTur = 'GELIR' | 'GIDER'
export type TahsilatTur = 'BILET' | 'ABONMAN'

export type BildirimTur =
  | 'YENI_UYELIK'
  | 'ABONMAN_BITIYOR'
  | 'VARDIYA_FARK'
  | 'TERK_EDILMIS'
  | 'DOLULUK'
  | 'BILET_IPTAL'
  | 'UCRET_DEGISIKLIGI'
  | 'PUAN_KULLANIM'
  | 'KAMERA'
  | 'ISTISNA'

export type PlakaSaglayici = 'KAPALI' | 'VLM' | 'ALPR'

/* --------------------------------------------------- display label tables */

export const ARAC_TIPI_ETIKET: Record<AracTipi, string> = {
  MOTOSIKLET: 'Motosiklet',
  OTOMOBIL: 'Otomobil',
  MINIBUS: 'Minibüs',
  KAMYONET: 'Kamyonet',
}

export const ODEME_ETIKET: Record<OdemeYontemi, string> = {
  NAKIT: 'Nakit',
  KREDI_KARTI: 'Kredi Kartı',
  HAVALE: 'Havale',
}

/** Chip colours per payment method. Tokens only — flips with dark mode. */
export const ODEME_CHIP: Record<OdemeYontemi, string> = {
  NAKIT: 'bg-nakit-soft text-nakit',
  KREDI_KARTI: 'bg-kart-soft text-kart',
  HAVALE: 'bg-havale-soft text-havale',
}

export const PARK_YERI_TIP_ETIKET: Record<ParkYeriTip, string> = {
  NORMAL: 'Normal',
  ENGELLI: 'Engelli',
  SARJ: 'Şarj',
}

export const ISTISNA_ETIKET: Record<IstisnaTur, string> = {
  GELECEK: 'Gelecek tarihli',
  BAYAT: 'Çok geç geldi',
  ACIK_BILET_YOK: 'Açık bilet yok',
  COKLU_ESLESME: 'Birden fazla eşleşme',
}

export const BILDIRIM_ETIKET: Record<BildirimTur, string> = {
  YENI_UYELIK: 'Yeni kayıt isteği',
  ABONMAN_BITIYOR: 'Abonman bitiyor',
  VARDIYA_FARK: 'Vardiya farkı',
  TERK_EDILMIS: 'Terk edilmiş araç',
  DOLULUK: 'Doluluk uyarısı',
  BILET_IPTAL: 'Bilet iptali',
  UCRET_DEGISIKLIGI: 'Ücret değişikliği',
  PUAN_KULLANIM: 'Puan kullanımı',
  KAMERA: 'Kamera',
  ISTISNA: 'Çözülmemiş kayıt',
}

/* ------------------------------------------------------------------- rows */

export interface Profile {
  id: string
  ad_soyad: string
  rol: Rol | null
  durum: KullaniciDurum
  notif_prefs: Record<string, boolean>
  created_at: string
}

export interface OtoparkAyarlari {
  id: number
  ad: string
  adres: string | null
  telefon: string | null
  kapasite: number
  plaka_saglayici: PlakaSaglayici
  plaka_model: string | null
  foto_saklama_gun: number
  kamera_gecikme_limiti_dk: number
  puan_aktif: boolean
  kamera_aktif: boolean
  kamera_varsayilan_arac_tipi: AracTipi
  terk_esik_saat: number
  doluluk_uyari_yuzde: number
  kamera_kalp_atisi: string | null
  kamera_kalp_esik_dk: number
  guncelleyen: string | null
  updated_at: string
}

export interface ParkYeri {
  id: string
  kod: string
  tip: ParkYeriTip
  rezerve: boolean
  is_active: boolean
  created_at: string
}

export interface Tarife {
  id: string
  arac_tipi: AracTipi
  ucretsiz_dakika: number
  ilk_saat_kurus: number
  sonraki_saat_kurus: number
  /** 0 means no daily cap. */
  gunluk_tavan_kurus: number
  kayip_bilet_kurus: number
  gecerli_baslangic: string
  gecerli_bitis: string | null
  olusturan: string | null
  created_at: string
}

export interface Vardiya {
  id: string
  personel_id: string
  acilis_at: string
  kapanis_at: string | null
  acilis_nakit_kurus: number
  beklenen_nakit_kurus: number | null
  sayilan_nakit_kurus: number | null
  fark_kurus: number | null
  notlar: string | null
}

export interface Abonman {
  id: string
  plaka: string
  musteri_ad: string
  musteri_tel: string | null
  baslangic: string
  bitis: string
  ucret_kurus: number
  park_yeri_id: string | null
  durum: AbonmanDurum
  notlar: string | null
  olusturan: string | null
  created_at: string
}

export interface Rezervasyon {
  id: string
  park_yeri_id: string
  abonman_id: string | null
  plaka: string | null
  /** tstzrange, serialised by PostgREST as e.g. ["2026-01-01 00:00+03",...) */
  gecerlilik: string
  notlar: string | null
  olusturan: string | null
  created_at: string
}

export interface Hesap {
  id: string
  ad: string
  telefon: string | null
  durum: HesapDurum
  notlar: string | null
  olusturan: string | null
  created_at: string
}

export interface HesapAraci {
  id: string
  hesap_id: string
  plaka: string
  created_at: string
}

export interface PuanKurali {
  id: string
  tekil: boolean
  kazanim_puan: number
  kurus_per_puan: number
  bekleme_saat: number
  puan_gecerlilik_gun: number
  gecerli_baslangic: string
  gecerli_bitis: string | null
  olusturan: string | null
  created_at: string
}

export interface Bilet {
  id: string
  islem_id: string
  plaka: string
  arac_tipi: AracTipi
  giris_at: string
  cikis_at: string | null
  tarife_id: string
  ucret_kurus: number
  indirim_kurus: number
  puan_kullanilan: number
  tahsil_kurus: number
  odeme_yontemi: OdemeYontemi | null
  durum: BiletDurum
  abonman_id: string | null
  park_yeri_id: string | null
  vardiya_id: string | null
  kapatan_vardiya_id: string | null
  giris_by: string | null
  cikis_by: string | null
  giris_kaynak: Kaynak
  cikis_kaynak: Kaynak | null
  giris_foto: string | null
  cikis_foto: string | null
  gecikmeli_kayit: boolean
  kaynak_zaman: string | null
  alindi_zaman: string | null
  kayip_bilet: boolean
  ucret_degistirildi: boolean
  ucret_sebep: string | null
  cikis_bekliyor_at: string | null
  iptal_sebep: string | null
  iptal_by: string | null
  iptal_at: string | null
  created_at: string
}

export interface PuanHareketi {
  id: string
  hesap_id: string
  tur: PuanHareketTur
  puan: number
  bilet_id: string | null
  kural_id: string | null
  aciklama: string | null
  created_by: string | null
  created_at: string
}

export interface Tahsilat {
  id: string
  tur: TahsilatTur
  bilet_id: string | null
  abonman_id: string | null
  tutar_kurus: number
  yontem: OdemeYontemi
  vardiya_id: string | null
  iptal_of: string | null
  aciklama: string | null
  created_by: string | null
  created_at: string
}

export interface KasaHareketi {
  id: string
  tur: KasaTur
  tutar_kurus: number
  kategori: string | null
  aciklama: string
  yontem: OdemeYontemi | null
  tarih: string
  created_by: string | null
  created_at: string
}

export interface Istisna {
  id: string
  tur: IstisnaTur
  yon: 'GIRIS' | 'CIKIS'
  plaka: string | null
  kaynak: Kaynak
  islem_id: string | null
  ham_yanit: Record<string, unknown> | null
  foto_path: string | null
  kaynak_zaman: string | null
  alindi_zaman: string
  aday_bilet_ids: string[] | null
  cozuldu_by: string | null
  cozuldu_at: string | null
  cozum_notu: string | null
  created_at: string
}

export interface PlakaOkumaLog {
  id: string
  saglayici: string
  ham_yanit: Record<string, unknown> | null
  guven: number | null
  onerilen: string | null
  kabul_edilen: string | null
  operator_id: string | null
  gecen_ms: number | null
  created_at: string
}

export interface Bildirim {
  id: string
  profile_id: string
  tur: BildirimTur
  baslik: string
  govde: string
  link: string | null
  read_at: string | null
  created_at: string
}

/* ------------------------------------------------------------ RPC results */

/** acik_bilet_ara() — a narrow projection, not the whole ticket row. */
export interface AcikBilet {
  id: string
  plaka: string
  arac_tipi: AracTipi
  giris_at: string
  abonman_id: string | null
  park_yeri_id: string | null
  cikis_bekliyor_at: string | null
  indirim_kurus: number
  puan_kullanilan: number
  tarife_id: string
  gecikmeli_kayit: boolean
}

export interface GunlukOzet {
  toplam_kurus: number
  arac_sayisi: number
  doluluk: number
  kapasite: number
}

export interface VardiyaOzet {
  vardiya_id: string
  acilis_at: string
  acilis_nakit_kurus: number
  nakit_kurus: number
  kart_kurus: number
  havale_kurus: number
  toplam_kurus: number
  bilet_sayisi: number
}

export interface AbonmanGecerlilik {
  gecerli: boolean
  bitis_tarihi: string | null
  musteri_ad: string | null
}

export interface PuanDurumu {
  hesap_var: boolean
  hesap_adi: string | null
  bakiye: number
  karsiligi_kurus: number
}

export interface BiletKapatSonuc {
  ucret_kurus: number
  indirim_kurus: number
  tahsil_kurus: number
}

export interface VardiyaKapatSonuc {
  beklenen_kurus: number
  sayilan_kurus: number
  fark_kurus: number
}

export interface RaporGun {
  gun: string
  ciro_kurus: number
  bilet_sayisi: number
  nakit_kurus: number
  kart_kurus: number
  havale_kurus: number
}

export interface RaporOzet {
  ciro_kurus: number
  bilet_sayisi: number
  ortalama_dakika: number | null
  abonman_giris: number
  saatlik_giris: number
  iptal_sayisi: number
  ucret_degisiklik_sayisi: number
  puan_borcu_kurus: number
}

/** plaka-oku Edge Function response. */
export interface PlakaOkumaSonuc {
  /** null when the read was too weak to prefill — show an empty field. */
  plaka: string | null
  guven: number
  saglayici: string
  log_id: string | null
  dusuk_guven: boolean
}
