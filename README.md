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

Four more fields decide where money lands in the ledger:

| Field | Purpose |
|---|---|
| Sales nominal code | Ledger account line items post to |
| Shipping nominal code | Ledger account shipping charges post to |
| Bank account | Account payments are recorded against |
| Payment method | KashFlow payment method used when recording a payment |

All four are required — there are no defaults, because a wrong nominal code
silently posts revenue to the wrong place.

**The first save always fails, and that's expected.** All six fields render from
the start, but the four dropdowns are populated by live lookups against the
connected account, which can only run once credentials are *persisted*. Since
all four are also validated as present and greater than zero, the first submit
cannot pass. The flow is:

1. Enter the API username and password. Leave the four dropdowns alone — they
   are empty.
2. Save. The form comes back with validation errors on the four numeric fields.
   This is the expected outcome, not a misconfiguration.
3. The dropdowns are now populated from the connected account. Pick all four.
4. Save again. This one succeeds.

If the dropdowns are still empty after step 2, the credentials were rejected —
re-check the two gotchas above.

No further setup is needed for metafields: this gem uses Spree's metafields
framework to track sync state and seeds its own `MetafieldDefinition` records on
first write, as **back-end only**. Nothing needs to be seeded by hand, and
nothing this gem stores (invoice numbers, customer codes, raw KashFlow error
text) is ever exposed on the storefront.

## Before you go live

**No payload in this gem has been verified against a live KashFlow account.**
Every field name, sequence order and value shape is inferred from the vendored
WSDL (`docs/kashflow-service.wsdl`) and from KashFlow's documented conventions;
the test suite asserts the SOAP request bodies this gem *sends*, but nothing has
been posted to a real account and read back. Verifying an invoice, a payment and
a credit note end-to-end against a live (or sandbox) KashFlow account is a
release gate, not an optional extra.

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
  wrong effective rate. KashFlow's `GetCurrencies` already returns the real
  rate and `Client#currencies` currently discards it, so this is the **top item
  for 0.2.0**.
- **`ValuesInCurrency` is not set, and is unverified.** KashFlow's invoice
  schema carries a `ValuesInCurrency` flag governing whether the amounts sent
  are in the order's currency or the account's base currency. This gem leaves it
  unset and has not confirmed which KashFlow assumes by default. Combined with
  the `ExchangeRate` limitation above, treat multi-currency as unsupported for
  now.
- **Orders that complete *unpaid* post an invoice that stays unpaid.** The only
  sync trigger is order completion; there is no `payment.completed` trigger. An
  order paid at checkout posts its payment along with the invoice, but an order
  completed on bank transfer, on account, or through any pay-later method
  (including Aypex's own `spree-bank_payments`) posts an invoice with `Paid` of
  `0` — and *nothing subsequently marks it paid in KashFlow* when the money
  actually arrives. Those payments have to be reconciled in KashFlow by hand
  until 0.2.0 adds a payment trigger.
- **Sequential partial refunds are not capped in aggregate.**
  `CreditNotePayload` decides full-versus-partial by comparing a *single*
  refund's amount against the order total, and nothing sums the credit notes
  already posted for an order. Several partial refunds against one order can
  therefore credit more than the order was worth. KashFlow may refuse the
  over-credit itself, but this gem does not prevent the attempt.
- **A fresh Savon client per call.** `Client` builds a new Savon client — and
  therefore refetches the 457&nbsp;KB WSDL — on every call. Rendering the admin
  configuration form makes four lookups, so four fetches. Functionally correct
  but wasteful; caching is a 0.2.0 item.

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
