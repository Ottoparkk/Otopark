# Anlaşmalı fiyat — design (2026-11-27)

## Why
The owner agrees a fixed price with some customers for a set time
("600 ₺ for 3 days", or hours). Staff need one button to record it, and the
car park must notice when the time is over without charging the customer
behind staff's back.

## Owner decisions
- Personel and Yönetici both create a deal; the Yönetici is notified.
- When the time is over the tariff counts again, but it is **not added
  automatically**: staff press "Fazla süreyi ekle" to add it.
- The İçeride card shows a warning ("Anlaşma bitti") for an expired deal.
- One notification to everyone at the moment the time runs out:
  "35 DGJ 457: anlaşma süresi doldu".
- Simple to use. Layout **E** (budget-app style): a time bar that fills up
  and turns orange when the time is over; the Oto yıkama drop icon stays.

## Approaches considered
- D: a text line ("Anlaşma 600 ₺, 30.11 13:03'e kadar"). Clear but gives no
  sense of how much time is left.
- **E (chosen by the owner):** the deal as a time budget with a progress
  bar, like Monzo / Revolut / Rocket Money spending limits.
- Separate columns (settings list, receipt): rejected by the owner as
  confusing.

## Rules (Claude's calls, the owner may overrule)
- The deal time counts from the car's entry; the end is entry + hours.
- Extra time is priced with the normal tariff as a new stay starting at the
  deal's end; once added it keeps counting until exit.
- Changing a deal clears "extra time added" and the expiry notification.
- The wash adds on top of the deal price. Points pay only the parking part
  (the deal price, plus added extra time).
- No deal for an abonman car. Duration 1 hour to 90 days.
- The Yönetici is notified on create/change, not on removal.
- Set from the ticket detail and Tahsilat (Hizmetler card), not from Giriş.

## Non-goals
- No automatic charge for extra time. No reminder before expiry.
- No report screen; the ticket and the notification are the record.
