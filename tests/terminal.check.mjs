// Ortak terminal (084, sahip 28.11): cihazın terminal kaydı ve PIN biçimi.
//
//   node tests/terminal.check.mjs
//
// Terminal kaydı `op.terminal` altında JSON olarak durur: {id, ad, gizli}.
// gizli 64 küçük hex olmalı; bozuk ya da eksik kayıt "terminal değil" (null)
// sayılır — bozuk bir kayıt giriş ekranını kilitlememeli. Çıkış (signOut)
// bu kaydı SİLMEZ: cihaz terminal olarak kalır.
import assert from 'node:assert/strict'
import { pinGecerli, terminalOku, terminalSil, terminalYaz } from '../src/features/terminal/terminal.ts'

function sahteDepo(ilk = {}) {
  const m = new Map(Object.entries(ilk))
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    _m: m,
  }
}

const GIZLI = 'a'.repeat(32) + '0123456789abcdef0123456789abcdef'
const KAYIT = { id: '11111111-2222-3333-4444-555555555555', ad: 'Gişe terminali', gizli: GIZLI }

// PIN: tam 4 rakam.
assert.equal(pinGecerli('0123'), true)
assert.equal(pinGecerli('9999'), true)
for (const yanlis of ['', '123', '12345', '12a4', ' 123', '١٢٣٤', null, undefined, 1234]) {
  assert.equal(pinGecerli(yanlis), false, `kabul edilmemeli: ${String(yanlis)}`)
}

// Yaz → oku.
let d = sahteDepo()
assert.equal(terminalOku(d), null)
terminalYaz(d, KAYIT)
assert.deepEqual(JSON.parse(d.getItem('op.terminal')), KAYIT)
assert.deepEqual(terminalOku(d), KAYIT)

// Bozuk JSON, eksik alan, yanlış gizli → null.
for (const ham of [
  '{bozuk',
  'null',
  '"metin"',
  JSON.stringify({ ...KAYIT, gizli: 'kisa' }),
  JSON.stringify({ ...KAYIT, gizli: GIZLI.toUpperCase() }),
  JSON.stringify({ id: KAYIT.id, gizli: GIZLI }),
  JSON.stringify({ ad: 'x', gizli: GIZLI }),
]) {
  assert.equal(terminalOku(sahteDepo({ 'op.terminal': ham })), null, `null olmalı: ${ham}`)
}

// Okuyamayan depo (kilitli tarayıcı) → null, patlamaz; depo yok → null.
assert.equal(terminalOku({ getItem() { throw new Error('SecurityError') } }), null)
assert.equal(terminalOku(null), null)

// Sil.
d = sahteDepo({ 'op.terminal': JSON.stringify(KAYIT), 'op.ekran.x': '1' })
terminalSil(d)
assert.equal(d.getItem('op.terminal'), null)
assert.equal(d.getItem('op.ekran.x'), '1', 'yalnızca terminal kaydı silinmeli')

console.log('terminal.check: tamam')
