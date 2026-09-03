/**
 * Turkish mobile numbers, as typed and as stored.
 *
 * STORED form is the national ten digits with no leading zero — that is what
 * the `^[1-9][0-9]{9}$` check on `abonmanlar.musteri_tel` and
 * `biletler.musteri_tel` accepts, and the server refuses anything else.
 *
 * TYPED form is whatever an operator writes, and in Turkey that is almost
 * always `0532 111 22 33`. Sending that raw got a Turkish refusal at the gate,
 * because stripping non-digits leaves eleven of them. So the trunk zero and a
 * +90 country code come off here, before the value is ever sent.
 */
export function normalizeTel(raw: string): string {
  const d = raw.replace(/\D/g, '')
  // Order matters: +90 first, since "+90 0532…" would otherwise leave a zero
  // in the middle of the result.
  const ulusal = d.startsWith('90') && d.length > 10 ? d.slice(2) : d
  return ulusal.startsWith('0') ? ulusal.slice(1) : ulusal
}

/** True when the value is storable — ten digits, first one not a zero. */
export function telGecerli(tel: string): boolean {
  return /^[1-9][0-9]{9}$/.test(tel)
}

/**
 * True when the field may be submitted: ten storable digits, OR deliberately
 * blank. Every caller's phone field is OPTIONAL, so this — not `telGecerli` —
 * is the question a submit handler is actually asking.
 *
 * It exists because two screens asked `telGecerli` directly and therefore
 * refused an EMPTY field while telling the operator "or leave it blank". On
 * the collection screen that also blocked saving the vehicle, name and note,
 * since one guard gates the whole form — and most tickets carry no phone, so
 * the edit was unusable rather than merely misworded.
 *
 * Normalising first is what keeps this honest: `ekBilgiGonder` sends
 * `normalizeTel(tel) || null`, so validating the same normalised value is the
 * only way the check and the send can agree by construction rather than by
 * two functions happening to be written the same way.
 */
export function telGonderilebilir(tel: string): boolean {
  const t = normalizeTel(tel)
  return t === '' || telGecerli(t)
}

/** "0532 111 22 33" from the stored "5321112233". */
export function formatTel(tel: string): string {
  if (!telGecerli(tel)) return tel
  return `0${tel.slice(0, 3)} ${tel.slice(3, 6)} ${tel.slice(6, 8)} ${tel.slice(8)}`
}
