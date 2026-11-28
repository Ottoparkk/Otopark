import { createPortal } from 'react-dom'
import type { FisSatiri } from './fisIcerik'

/**
 * Draws a fiş's lines. The same markup is the on-screen preview (inside the
 * sheet) and the paper (a portal straight under <body>): `@media print` in
 * index.css hides every other child of <body> and lays `.fis-baski` out
 * 48 mm wide on a 58 mm roll — the layout the P2 printed correctly from
 * Chrome on 25.11 (tools/cihaz-testi/yazici).
 */
export function FisKagidi({ satirlar }: { satirlar: FisSatiri[] }) {
  return (
    <div className="fis-kagit font-mono text-label leading-snug text-ink">
      {satirlar.map((s, i) => (
        <FisSatir key={i} s={s} />
      ))}
    </div>
  )
}

function FisSatir({ s }: { s: FisSatiri }) {
  switch (s.t) {
    case 'baslik':
      return <p className="fis-baslik text-center font-bold">{s.metin}</p>
    case 'alt':
      return <p className="fis-alt text-center">{s.metin}</p>
    case 'buyuk':
      return <p className="fis-buyuk my-1 text-center text-title font-bold tracking-wide">{s.metin}</p>
    case 'satir':
      return (
        <p className={`fis-satir flex justify-between gap-2 ${s.kalin ? 'fis-kalin font-bold' : ''}`}>
          <span>{s.sol}</span>
          <span className="text-right tnum">{s.sag}</span>
        </p>
      )
    case 'cizgi':
      return <hr className="fis-cizgi my-1.5 border-0 border-t border-dashed border-current" />
    case 'not':
      return <p className="fis-not text-center">{s.metin}</p>
  }
}

/** The paper copy: rendered only while a fiş is ready to print. */
export function FisBaskiPortal({ satirlar }: { satirlar: FisSatiri[] }) {
  return createPortal(
    <div className="fis-baski" aria-hidden>
      <FisKagidi satirlar={satirlar} />
    </div>,
    document.body,
  )
}
