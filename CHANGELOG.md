# Changelog

## 0.1.1

- **Fix: every order sync failed against a live KashFlow account.** The customer
  `Code` was set to the order's email address, which KashFlow rejects — "the
  customer code specified is invalid, please re-enter without any special
  characters" — on the customer upsert, before an invoice was ever attempted.
  Codes are now uppercase-alphanumeric and derived from the customer rather than
  the order: `SPU<user id>` for a registered user, `SPG<email digest>` for a
  guest. Both are stable across that customer's orders, which is what keeps
  `InsertCustomer` an update rather than a duplicate.
- Require `digest` explicitly rather than relying on a transitive dependency to
  load it.
- Replace the placeholder integration logo with the IRIS KashFlow brand asset.

## 0.1.0

- Initial release.
- Pushes completed orders to KashFlow as invoices over the SOAP API, with the
  customer upserted and the payment recorded.
- Pushes refunds as credit notes (negative invoices) linked to the original
  invoice.
- Configured per store through Spree's Integrations framework; nominal codes and
  bank account are chosen from the connected KashFlow account.
- Refuses to post an invoice whose assembled total does not match the order
  total, recording the failure instead.
- Requires Spree >= 5.6. No migrations.
