# Oto yıkama — design (short)

**Status:** draft, waiting for owner approval (27.11.2026).
Mockups: Tarife, A, B2, C, İçeride list 2. These were sent to the owner as photos;
the throwaway HTML lives in the session scratchpad.

## Why

The car park now also offers a car wash, and some customers use it (owner).
The wash fee has to end up on the same ticket and be collected with the
parking fee.

## What the owner decided

- **Price:** a Yönetici enters "Oto yıkama ücreti (₺)" in Tarife.
- **Where the wash is added:** a switch in three places:
  - **A, Giriş:** an "Oto yıkama +150 ₺" switch above "Giriş Ver".
  - **B2, ticket detail (içeride):** a separate **HİZMETLER** card between the
    fee card and the BİLET card. Its heading looks exactly like **BİLET**
    (bold, ink). It holds an "Otopark 200 ₺" row, then the "Oto yıkama +150 ₺"
    switch.
  - **C, Tahsilat:** the same switch under the big amount, plus an
    "Oto yıkama 150 ₺" row in the BİLET card.
- **Icon, not emoji:** a new line icon `IconYikama` (water drop) in
  `src/components/ui/icons.tsx`, in the same style as the other icons.
- **İçeride list:** a car getting a wash shows the drop as a round accent badge
  on the top-left corner of its car box (mockup "liste 2").

## My calls (open to the owner's correction)

1. **Empty price = feature off.** With no wash price in the tariff, no switch
   shows anywhere.
2. **The price is locked when the wash is added.** The ticket stores the wash
   price at that moment. A later tariff change doesn't touch it, the same way
   parked cars keep their entry tariff.
3. **The server adds it.** The parking fee plus the wash price is the ticket
   fee, priced on the server (the list, the detail, Tahsilat and `bilet_kapat`
   all show the same figure). The client never sends an amount, only on/off.
4. **Who:** Personel and Yönetici, only while the ticket is open. A closed
   ticket stays immutable (`biletler_immutable_guard`).
5. **Abonman cars pay for the wash.** Parking stays free; the list shows
   "Ücretsiz + 150 ₺".
6. **"Ücretsiz" exit makes the wash free too.** It zeroes the whole ticket,
   with the reason it already asks for. The Yönetici is notified as today.
7. **Collection is unchanged.** It is one amount through `bilet_kapat` and
   waits in Onay like every payment.
8. **The camera never adds a wash.** Only people do.

## Non-goals (for now)

- A separate wash line or total in Raporlar, Kasa or Vardiya.
- More than one service, or several wash types and prices.
- Adding a wash after the car has left.

## Approaches considered

- Only at Giriş (A): fails when the customer decides later.
- Only at Tahsilat (C): easy to forget, so a washed car leaves unpaid.
- A button in the BİLET heading next to Değiştir (the first B): the owner
  rejected it and asked for a redesign, which became B2.
- **Chosen:** A + B2 + C with one shared switch, plus the list badge.

## Build order (project rule: tests first)

1. Smoke test `PASS N` blocks in `supabase/tests/rls_smoke_test.sql`: tariff
   price Yönetici-only; Personel can switch the wash on an open ticket, but not
   on a closed or another shift's ticket; the price is locked; the fee includes
   the wash; abonman is charged only the wash; Ücretsiz zeroes it; the function
   grants are checked.
2. Migration 078 (a new tariff column and ticket columns, an RPC to switch the
   wash, and the fee and list functions updated).
3. Screens: Tarife, Giriş, BiletDetay (HİZMETLER), Tahsilat, BiletKart badge.
   Checked in the harness at 360 / 375 / 430 px and in dark mode before the
   commit.
