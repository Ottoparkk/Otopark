# Süre aşımı onayı — design (short)

**Owner, 27.11.2026:** a normal ticket must not go past the first tier's price (200 ₺ today). When the car stays longer, the ticket shows a report: how long it stayed and what the tariff price would be, with an Onayla button.

## Decisions (owner)
- **The cap** is the tariff's first tier, so it follows the Tarife screen.
- **Who decides:** Personel and Yönetici, and the Yönetici is notified of every decision.
- **Choices:** "Onayla" charges the full tariff price. "<ilk kademe> kalsın" keeps the first tier.
- **Before exit:** no person's exit and no collection until someone decides. The camera can't decide, so it closes the ticket unpaid at the first tier, and the decision is made before the payment is collected.

## Calls I made
- **Scope:** KADEMELI tariffs only. Only they have "ranges"; SURELI and SABIT are unchanged.
- **Exempt tickets:** abonman (always 0) and deal tickets (080). A person already set those prices.
- **Already a decision:** a hand-set fee (with a reason) and a free exit each count as the decision.
- **Once only:** a ticket can be decided once. The decision is audited and the Yönetici is notified.
- **Closed tickets:** the decision follows 066's rule: own shift or Yönetici, nothing collected. The guard gets a narrow `app.bilet_asim` exception for `ucret_kurus` and the `asim_*` fields.

## Approaches
1. **Cap inside `bilet_ucreti`, the single pricing point (chosen).** Every path (exit, camera, preview, list, points) gets it at once. Exit and collection get a gate.
2. Cap only in the UI. Rejected: the server prices every fee.
3. Store a separate "approved extra" amount. Rejected: it is more state for the same result.

## Build
- Migrations: 081 (enum `SURE_ASIMI`) and 082.
- Smoke test: PASS 108–111.
- Client: `src/features/gise/asim.ts` (checked by `tests/asim.check.mjs`), `AsimBlogu` and `useAsim` in `components.tsx`, the "Süre aşımı" chip on the İçeride card, and the decide-first message on Tahsilat and on "Ödeme topla".
