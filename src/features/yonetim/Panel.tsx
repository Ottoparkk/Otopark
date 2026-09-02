import { Link } from 'react-router'
import { ScreenHeader } from '../../components/ui/primitives'
import { useAyarlar } from '../gise/api'
import { MenuKart } from './components'
import {
  IconAbonman,
  IconAyar,
  IconCop,
  IconKisi,
  IconPuan,
} from '../../components/ui/icons'

/**
 * Yönetim is operations and configuration only — money lives in Finans.
 *
 * The menu is deliberately SHORT. It was eight tiles across two headed groups,
 * which is a wall to read every time you want one thing. Three of them earned
 * their way off it rather than merely being hidden:
 *
 *  - Bildirimler lives in the desktop top bar. It briefly had a bell here as
 *    well; that was removed at the owner's request, and with it the occupancy
 *    badge — this screen carries no live figures at all now, only the way in
 *    to each area.
 *  - Tarifeler moved to Finans. Prices are the single biggest determinant of
 *    revenue, so that is where someone goes looking for them.
 *  - Puan hesapları appears only when the points feature is actually ON. It
 *    ships off, and a tile leading to an inert screen is worse than no tile.
 *
 * What is left is one column of full-width rows, short enough to need no
 * group headings.
 *
 * No lira figure appears anywhere on this screen, and no live figure either —
 * that separation from Finans is the whole reason the two are different
 * screens. Occupancy lives on Gişe, where an operator watches it all day.
 */
export default function Panel() {
  const { data: ayarlar } = useAyarlar()

  // `=== true`, not a truthy check: this is undefined while the settings row is
  // still loading, and points ship OFF, so the common case renders its final
  // layout immediately instead of showing a tile and snatching it back.
  const puanAcik = ayarlar?.puan_aktif === true

  return (
    // The header sits INSIDE the centred wrapper. ScreenHeader carries its own
    // padding and is shared by every screen, so centring only the body would
    // leave "Yönetim" hanging to the left of the cards it labels — the exact
    // bug Finans had until this container was put round both.
    <div className="md:mx-auto md:max-w-[900px]">
      <ScreenHeader title="Yönetim" />

      <div className="space-y-5 px-5">
        {/* One column at every width. Capped rather than run out to the
            shell's full 1052: a menu row a metre wide is a stretched phone,
            not a dashboard. */}
        <div className="grid grid-cols-1 gap-3">
          <MenuKart
            satir
            to="/yonetim/abonman"
            tone="success"
            icon={<IconAbonman size={22} />}
            baslik="Abonmanlar"
            aciklama="Aylık müşteriler ve tahsilat"
          />
          {/* Each destination its own tile colour: four rows of the same grey
              turned the icon into decoration and the list read as four lines
              of text. Money stays green, people teal, points amber, the lot's
              own settings magenta — Profil keeps neutral, because it belongs
              to the utility row below rather than to this menu. */}
          {puanAcik && (
            <MenuKart
              satir
              to="/yonetim/hesaplar"
              tone="warn"
              icon={<IconPuan size={22} />}
              baslik="Puan hesapları"
              aciklama="Hesaplar ve bakiyeler"
            />
          )}
          <MenuKart
            satir
            to="/yonetim/personel"
            tone="accent"
            icon={<IconKisi size={22} />}
            baslik="Personel"
            aciklama="Kayıt onayı, rol ve durum"
          />
          <MenuKart
            satir
            to="/yonetim/ayarlar"
            tone="mor"
            icon={<IconAyar size={22} />}
            baslik="Otopark ayarları"
            aciklama="Kapasite, kamera, plaka okuma, puan"
          />
        </div>

        {/* Out of the menu and onto its own row with the bin. Everything in
            the list above is about running the car park; these two are the
            utilities beside it — the person's own account, and the place
            deleted records land. Compact, so the row reads as a footer to the
            menu rather than another entry in it. Notifications live INSIDE
            Profil rather than beside it: the preferences were already there,
            and a second row pointing at the same subject is how a menu stops
            being scannable. */}
        {/* Side by side from md, stacked on a phone. Sharing the row at 375px
            leaves the card ~171px wide, which wraps "Hesap bilgileri,
            bildirimler, çıkış" onto three lines beside a 46px pill. */}
        <div className="flex flex-col items-end gap-3 md:flex-row md:items-center">
          <div className="w-full md:min-w-0 md:flex-1">
            <MenuKart
              satir
              kucuk
              to="/ayarlar"
              icon={<IconKisi size={18} />}
              baslik="Profil"
              aciklama="Hesap bilgileri, bildirimler, çıkış"
            />
          </div>
          <CopButonu />
        </div>
      </div>
    </div>
  )
}

/**
 * Çöp Kutusu, set apart from the menu rather than listed in it.
 *
 * It is not a destination you go looking for the way you go looking for
 * Personel — it is where you go the moment after deleting something by
 * mistake. Off the list it stops competing with the four places that are part
 * of running the car park.
 *
 * In the FLOW and right-aligned, not `fixed` to the viewport corner. The menu
 * is capped at 860px and centred, so a viewport-pinned button sits a couple of
 * hundred pixels out in the margin with nothing around it — attached to the
 * window instead of to the screen it belongs to. Right-aligned under the list
 * it lands on the column's own edge at every width.
 *
 * Labelled, like the Giriş button on Gişe: a lone bin glyph is a guess, and
 * there is room for two words.
 */
function CopButonu() {
  return (
    <Link
      to="/yonetim/cop"
      className={[
        // The white pill is deliberately SHORTER than the red square, which
        // overhangs it top and bottom. So no overflow-hidden — clipping is
        // exactly what would flatten the two back into one rectangle — and the
        // square is positioned rather than laid out in the row, so the pill's
        // height is set by its own text and never grows to contain it.
        'relative flex min-h-[46px] items-center rounded-chip border border-border',
        'bg-surface py-2 pr-[62px] pl-5 shadow-raised',
        'transition-transform duration-100 active:scale-[0.97]',
      ].join(' ')}
    >
      <span className="text-body font-semibold text-ink">Çöp Kutusu</span>
      {/* Not IconTile: that is a fixed square sized to sit INSIDE a card, and
          this one has to stand proud of one. danger, not neutral — red is what
          makes a bin read as a bin at a glance, and this is the one control on
          the screen that undoes a deletion. */}
      <span
        className={[
          'absolute top-1/2 right-0 -translate-y-1/2',
          'flex size-14 items-center justify-center rounded-field',
          'border border-border bg-danger-soft text-danger shadow-card',
        ].join(' ')}
      >
        <IconCop size={24} />
      </span>
    </Link>
  )
}
