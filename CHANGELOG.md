# Changelog

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
