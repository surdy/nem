# nem

A routine task tracker for iOS and Android. Set schedules for recurring
household and maintenance work, and mark it done by scanning an NFC tag, a QR
label, or a product barcode on the thing itself.

Flutter. Local-first, with optional sync via Supabase (cloud or self-hosted).

## Docs

- [CONTEXT.md](./CONTEXT.md) — the domain glossary. Read this first.
- [PLAN.md](./PLAN.md) — schema, sync design, scan flow, build phases.
- [docs/adr](./docs/adr) — architecture decision records.

## Status

All four phases in [PLAN.md](./PLAN.md) have landed: the due date engine and
both schedule modes, tags, labels and barcodes, two-device sync over Supabase,
and the rest — categories, notes, reference photos, reminders, history, snooze
and archive.

Running it on an iPhone still needs a paid Apple Developer Program membership,
which is what Core NFC is gated behind and what keeps a build installed beyond
seven days (ADR 0009). Android carries no equivalent cost.
