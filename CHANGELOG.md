# Changelog

## 0.1.3

- **Fix: `upsert_customer` only ever inserted.** KashFlow publishes no
  `InsertOrUpdateCustomer`, and the client called `InsertCustomer`
  unconditionally with no lookup. 0.1.1 made customer codes stable per customer
  — which is what keeps one KashFlow customer per Spree customer rather than one
  per order — and that turned the missing lookup into a hard failure: the insert
  succeeded exactly once, and the same customer's *second* order was rejected
  with `Customer Code is not unique`, posting no invoice. `upsert_customer` now
  looks the code up with `GetCustomer` and either `UpdateCustomer`s the existing
  record or `InsertCustomer`s a new one, so it is idempotent across repeated
  syncs.
- `CustomerID` is prepended to the update payload rather than merged onto the
  end, because it is the first element of the WSDL's `Customer` sequence and an
  ASMX endpoint enforcing that sequence drops or mis-binds an out-of-order
  element rather than raising — an update whose id was dropped would write to
  the wrong customer, or to none, and still return successfully.
- How KashFlow signals "no such customer" on `GetCustomer` is undocumented, so
  both plausible shapes are treated as absent: an empty result, and an in-band
  business rejection. Only `ApiError` is swallowed; an authentication or
  transport failure keeps propagating rather than being read as "absent" and
  turned back into a duplicate insert.

## 0.1.2

- **Fix: every order sync still failed against a live KashFlow account**, now on
  the invoice rather than the customer. KashFlow types every date field in the
  WSDL as `s:dateTime`, and its .NET `XmlSerializer` rejected the whole envelope
  with `The string '2026-08-18 10:53:48 UTC' is not a valid AllXsd value` —
  no invoice created, and the fault naming only a character offset. Gyoku
  type-switches with `Module#===`, so `ActiveSupport::TimeWithZone` (a
  delegator, not a `Time` subclass) fell through to `to_s`; plain `Time` did
  too, and `Date` emitted an xsd `date` rather than a `dateTime`. Since
  `Time.current` and Active Record datetime attributes all return
  `TimeWithZone`, this was the default path, affecting `InvoiceDate`, `DueDate`
  and `PayDate` on orders and `InvoiceDate` / `DueDate` on refunds.
  `Client#call` now normalises every temporal value in an outgoing message to
  UTC xsd `dateTime`, so the wire format is owned by the one class that touches
  the wire and any date field added later is correct by default.
- Assert the *serialised* SOAP body for temporal values. The suite doubled the
  client and asserted the payload Hash, where a `TimeWithZone` looks correct
  right up until it reaches the wire — which is why 0.1.1 shipped with this
  defect behind a green build.

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
