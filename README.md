# Spree::Kashflow

A [Spree](https://github.com/spree/spree) extension that posts completed orders to
[KashFlow](https://www.kashflow.com/) as invoices, and refunds as credit notes, over
KashFlow's SOAP API.

## Why SOAP, not REST?

KashFlow has two APIs. The REST API's own docs carry a production disclaimer —
["you should not be using it in a production environment"](https://api.kashflow.com/) —
that has stood, unrevised, since October 2018. The SOAP API is the one KashFlow
actually supports for production integrations, so that's what this gem uses.

## Installation

```bash
bundle add spree-kashflow
```

Requires Spree >= 5.6 and Ruby >= 3.3. There are no migrations and no generator to
run — installing the gem and restarting the app is the whole install.

## Configuration

In the Spree admin, go to **Configuration → Integrations → New Integration** and
choose **KashFlow** (listed under the "Accounting" group).

Enter your KashFlow **API username** and **API password**. Two things trip people up
here:

- The **SOAP API must be explicitly enabled** on the KashFlow account before these
  credentials will work — it's not on by default.
- The KashFlow **API password is often not the same as the login password**. Check
  KashFlow's API settings for the credentials it issues specifically for API access.

Once valid credentials are saved, four more fields appear, populated as dropdowns
fetched live from the connected account:

| Field | Purpose |
|---|---|
| Sales nominal code | Ledger account line items post to |
| Shipping nominal code | Ledger account shipping charges post to |
| Bank account | Account payments are recorded against |
| Payment method | KashFlow payment method used when recording a payment |

All four are required — there are no defaults, because a wrong nominal code
silently posts revenue to the wrong place.

No further setup is needed for metafields: this gem uses Spree's metafields
framework to track sync state, and `set_metafield` auto-creates its
`MetafieldDefinition` the first time it's called. Nothing needs to be seeded.

### Wiring the customer's VAT number

Spree has no dedicated column for a customer's VAT number, and this gem does not
invent one. `Spree::Kashflow::CustomerPayload` reads it from
`order.metadata["vat_number"]` — but **nothing in Spree or this gem writes that
key**. If your store needs `VATNumber` sent to KashFlow (for EC-zone B2B
customers, for example), your host application must populate
`order.metadata["vat_number"]` before the order completes. Left unset, the
customer payload simply omits `VATNumber` — no error, just silently absent.

## Behaviour

A sync is triggered by:

- **Order completion** — the `order.completed` event enqueues `SyncOrderJob`,
  which upserts the customer, posts the invoice, and (if the order is paid)
  records the payment.
- **A reimbursement** — the `reimbursement.reimbursed` event enqueues
  `SyncRefundJob` for each refund it produced.
- **Any refund** — a decorator on `Spree::Refund` enqueues `SyncRefundJob` on
  every refund's creation, independent of the reimbursement flow. This covers
  an admin issuing an ad-hoc refund directly against a payment, which Spree
  doesn't route through a reimbursement event.

Syncs are **idempotent**: `SyncOrderJob` no-ops once the order carries a
`kashflow.invoice_number` metafield, and `SyncRefundJob` no-ops once the refund
carries a `kashflow.credit_note_number` metafield. The same order or refund
firing more than one trigger — or a job retrying — never double-books.

A sync **never blocks checkout**. Both jobs run asynchronously via Active Job,
after the order has already completed or the refund has already been created.
Nothing in the checkout or refund path waits on KashFlow.

## The correctness guard

Before posting anything, this gem assembles the invoice's line items and checks
that they reconcile — both individually (`Rate * Quantity` against each line's
net total) and in aggregate (the assembled invoice total against
`order.total`). If they don't match, **nothing is posted**. Instead, the gem
raises `Spree::Kashflow::TotalMismatchError`, and the failing job records the
error message on the order's `kashflow.sync_error` metafield.

This is deliberate, not a limitation to work around. A failed sync is a
queryable flag your team can find and fix. A wrong invoice is a discrepancy
someone finds at year end, after it's been sitting in KashFlow's ledger for
months. Refusing to post is the safer failure mode.

One consequence: **orders with exclusive tax are refused, not mis-booked.** The
guard's arithmetic only accounts for VAT baked into the price
(`included_tax_total`); an order carrying `additional_tax_total` (tax added on
top of the price rather than included in it) will never reconcile, and will
always be refused with a sync error rather than posted with wrong figures.

### Finding failed syncs

Query orders (or refunds) carrying a `kashflow.sync_error` metafield:

```ruby
Spree::Order.with_metafield_key("kashflow.sync_error")
```

The metafield's value is the error message from the failed attempt. It is
cleared automatically on the next successful sync.

## Known limitations

- **Partial refunds are approximated, not apportioned.** Spree carries no
  information tying a partial refund back to specific line items or their
  individual VAT rates. A full refund mirrors the original invoice's lines
  exactly, negated. A partial refund instead posts as a **single negative
  line**, at the order's *blended* VAT rate (`order.included_tax_total /
  (order.total - order.included_tax_total)`), rather than apportioned across
  the lines it actually came from. Apportioning without that information would
  mean inventing numbers in an accounting ledger, which this gem avoids.
- **`Sort` on invoice lines is a placeholder.** Lines are sent with a 1-based
  index in `Sort` (line items first, then shipping). This is KashFlow's line
  ordering field, but its effect on the rendered invoice has not been
  confirmed against a live KashFlow account.
- **`ExchangeRate` is hardcoded to `1`.** Before posting, this gem confirms the
  order's currency is *enabled* on the connected KashFlow account — but an
  enabled currency isn't necessarily at parity with the account's base
  currency. No currency conversion is performed. Multi-currency accounts where
  the order currency differs from KashFlow's base currency will post at the
  wrong effective rate.

## Development

```bash
bundle install
bundle exec rake test_app
bundle exec rspec
bundle exec standardrb
```

## Licence

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
