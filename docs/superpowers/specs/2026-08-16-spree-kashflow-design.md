# spree-kashflow — design

Date: 2026-08-16
Status: awaiting review

## Problem

TKF's completed orders and refunds are not reaching KashFlow. Every sale has to be
re-entered by hand, or reconciled later from exports, and refunds make the two
sets of books drift apart.

A predecessor exists — `MatthewKennedy/spree_kashflow`, a detached copy of
`ronzalo/spree_kashflow` (author Gonzalo Moreno), last touched April 2018,
targeting Spree 3.1–4.0 with six model decorators, two migrations against
`spree_orders`, no tests beyond a `spec_helper`, and never published to
RubyGems. Its *payload shapes* are still a useful reference. None of its
structure is.

This gem is a new build against Spree 5.6, following `aypex-io/spree-shipstation`
and Spree's Integrations framework.

## Scope

In scope:

- Completed orders pushed to KashFlow as invoices, with the customer upserted
  and the payment recorded.
- Refunds pushed as credit notes — **both** refund paths (see "Triggers").
- Per-store credentials, configured in the Spree admin's Integrations section.
- All currencies the KashFlow account has enabled.

Out of scope:

- Any pull from KashFlow into Spree. KashFlow must not become a competing source
  of truth for customers or products.
- Quotes, purchases, journals, bank reconciliation, projects.
- An admin retry workflow or sync audit table (see "Rejected approaches" — this
  is the most likely thing to add in 0.2.0).

## Constraints

- Spree **>= 5.6.0**, Ruby **>= 3.3**.
- Follow `spree-shipstation`: `Spree::Integration` subclass, admin form partial,
  registration via `config/initializers/spree.rb`.
- Scaffold with **`rails plugin new`**, not `bundle gem` and not by hand: this is
  an engine (it ships `app/`), and the `develop-ruby-gem` skill reserves
  `bundle gem` for plain and Railtie gems. Conform the generated skeleton to the
  Spree extension conventions afterwards rather than hand-building it.
- **Runtime dependencies in the gemspec, development dependencies in the
  Gemfile** (`spree-fixed_amt_discount` put `spree_dev_tools` in the gemspec;
  that is the wrong side of the line).
- `# frozen_string_literal: true` on every Ruby file, without exception.
- **YARD on every public class and public method**, verified with
  `yard stats --list-undoc`.
- TDD per the shared contract: first red must be an **assertion** failure, not a
  `NameError` — add the empty class or method, then show the assertion failing,
  then implement.
- **No migrations and no install generator.** Sync state lives in metafields.
- Exactly **one** decorator in the whole gem (`Spree::Refund`), and it may only
  enqueue a job.
- Never place a KashFlow call in a customer-facing request cycle.

## The API decision: SOAP, not REST

Build against the **SOAP** API (`https://securedwebapp.com/api/service.asmx?WSDL`).

KashFlow's REST API is not usable. Its own documentation — reviewed 2026-08-16,
last updated 2026-03-09 — states: *"The REST API is a work in progress and as
such is subject to change. You should not be using it in a production
environment."* The public feature request "Finish the REST API"
(kashflow.ideas.aha.io/ideas/KF-I-3297) was opened January 2017; the last
official response, October 2018, put it at *"roughly 50% complete"* and said it
would not be *"delivering completely at any point in the near future"*. There has
been no vendor update since. A user comment in February 2022 notes nine years had
then passed since the REST API was announced. Status is still "Started".

So REST has carried a production disclaimer for roughly thirteen years with no
movement in eight, while customers migrated away over it. The SOAP API carries no
deprecation notice and covers everything needed: `InsertCustomer`,
`InsertInvoice`, `InsertInvoiceLine`, `InsertInvoicePayment`, credit notes,
`GetCustomersModifiedSince`.

Authentication is `UserName` / `Password` on **every** call — there is no session
token, so the client is stateless. The SOAP API must be explicitly enabled on the
KashFlow account, and the API password is often not the login password.

`savon` 2.17.4 (released 2026-07-03) installs cleanly on Ruby 4.0.1 — verified
2026-08-16. This was the main dependency risk and it is closed.

## Approach

Events → background jobs → a thin SOAP client, with sync state in metafields.

```
order.completed ─────────────┐
reimbursement.reimbursed ────┼──▶ Sync*Job ──▶ Payload mapper ──▶ Client ──▶ KashFlow SOAP
Spree::Refund after_create ──┘         │              │
                                       └── metafields ┘
```

### Rejected approaches

**A dedicated `spree_kashflow_syncs` table (outbox).** A row per attempt with
status, payload, response and error gives a real audit trail and an admin retry
workflow — a genuine argument for accounting. Rejected for 0.1.0 because it costs
a migration, an install generator, an admin screen and a schema, and metafields
already make "what has not reached the books?" a normal query. It is additive
later: the mappers and client do not move. Revisit if the need is *reconciling
disputes about what was sent*, rather than *detecting failures*.

**Synchronous push in the request cycle.** `spree-shipstation` captures payments
synchronously, but that is a webhook responding to ShipStation. Putting an
accounting SOAP call in order completion means KashFlow being slow or down
degrades checkout.

**Porting the 2018 gem.** Six decorators and two migrations against
`spree_orders`, against a Spree four majors old, with no tests to port.

## Components

### `Spree::Integrations::Kashflow`

`app/models/spree/integrations/kashflow.rb`

```ruby
class Kashflow < Spree::Integration
  preference :username, :string
  preference :password, :password
  preference :sales_nominal_code, :integer     # InvoiceLine#ChargeType for product lines
  preference :shipping_nominal_code, :integer  # InvoiceLine#ChargeType for the shipping line
  preference :bank_account_id, :integer        # Payment#PayAccount
  preference :payment_method_id, :integer      # Payment#PayMethod
end
```

The four numeric preferences are **accounting configuration, not implementation
detail** — they decide which ledger accounts the money lands in, and a wrong
value posts real revenue to the wrong nominal code. They were not in the first
draft of this spec; the WSDL revealed that `InvoiceLine#ChargeType` and
`Payment#PayAccount` / `#PayMethod` are required identifiers with no sensible
default.

`GetNominalCodes` and `GetBankAccounts` both exist on the API, so the admin form
populates these as **dropdowns fetched from the connected account** rather than
free-text integers. Free text here would be an invitation to mis-post.

`integration_group` is `"Accounting"`; `icon_path` points at a bundled logo;
`can_connect?` makes one cheap authenticated call so an admin learns credentials
are wrong when saving, not at the first order.

Credentials are per-store — `Spree::Integration` belongs_to store, which matters
for TKF's multi-market setup.

### `Spree::Kashflow::Client`

`lib/spree/kashflow/client.rb`

The only file in the gem that knows SOAP exists. Constructed with credentials;
exposes `verify_credentials`, `upsert_customer`, `create_invoice`,
`record_invoice_payment`, `create_credit_note`, `currencies`. Returns plain Ruby
— never a savon object crosses this boundary.

Errors normalise to `Spree::Kashflow::AuthenticationError`, `ApiError`,
`TransportError`.

This seam exists for **testability**, not for a future REST migration. SOAP is
miserable to test through; isolating it lets the domain logic be tested as plain
Ruby. Given the REST evidence above, a transport swap is not an expected event.

### Payload mappers

`app/presenters/spree/kashflow/{customer,invoice,credit_note}_payload.rb`

Pure objects: Active Record in, hash out, no network. This is where the money
arithmetic lives and where most of the test value sits.

**Line mapping.** TKF is VAT-inclusive; KashFlow wants net rates. Per line item:

```
discounted_gross = line_item.amount + line_item.promo_total   # promo_total is negative
net_total        = discounted_gross - line_item.included_tax_total
Rate             = net_total / quantity
VatAmount        = line_item.included_tax_total
Description      = "<product name> (<promotion codes> applied)"
```

Shipping becomes its own line on the same basis. Note `line_item.amount` is
`price * quantity` **before** discounts, and `promo_total` is negative — hence
the addition.

**Unit-rate rounding.** `Rate` is a per-unit figure, so `net_total / quantity`
can produce more decimal places than KashFlow accepts, and rounding it means
`Rate * quantity` no longer equals `net_total` — a line of 3 at a net total of
10.00 cannot be expressed as a 2dp unit rate at all. The mapper must therefore
decide, from the WSDL, how many decimal places `Rate` carries, and reconcile the
difference rather than let it drift silently.

This is the same failure mode that produced the surcharge defect in
`spree-fixed_amt_discount`: a per-unit rounding that looks harmless until it is
multiplied back up. The correctness guard below is what catches it, and a test
must cover a quantity > 1 line whose net total does not divide evenly.

**Discount presentation.** Discounted unit rates, with the promotion named in the
line description. Chosen over a separate negative discount line because a
promotion spanning items on *different* VAT rates has no single correct rate;
representing it correctly would need one negative line per VAT rate, making the
invoice less readable rather than more. This matters immediately: TKF now runs
`spree-fixed_amt_discount`, whose whole purpose is spreading one discount across
line items that may sit on different tax categories.

> If the person who reconciles the accounts expects gross-then-discount on the
> invoice, that preference outranks this decision and the mapper changes.

**Currency.** The invoice carries the order's currency. KashFlow raises invoices
in foreign currencies, but each currency must already be enabled on the account
and is referenced by a currency identifier. The mapper resolves the order's
currency against the account's enabled list and **raises if it is absent** —
booking a USD order as GBP is worse than not booking it.

### The correctness guard

Before anything is posted, the invoice mapper asserts that **the assembled
invoice total equals the order total**. On mismatch it raises and posts nothing.

This is deliberate and load-bearing. The sibling gem `spree-fixed_amt_discount`
shipped with a rounding defect that produced a positive (surcharge) adjustment on
a line item while leaving the *order* total correct — it survived every
order-level test and was caught only by per-item inspection. An accounting
integration that silently books slightly-wrong numbers is worse than one that
visibly refuses: a failed sync is a queryable flag, a wrong invoice is a
discrepancy someone finds at year end.

### Triggers

| Trigger | Path | Notes |
|---|---|---|
| `order.completed` | subscriber → `SyncOrderJob` | Core event, no decorator |
| `reimbursement.reimbursed` | subscriber → `SyncRefundJob` | Core event, returns flow |
| `Spree::Refund` created | `after_create_commit` decorator → `SyncRefundJob` | The only decorator |

Spree 5.6 publishes no `refund.created` event, and the returns flow
(`reimbursement.reimbursed`) does not cover an admin issuing an ad-hoc refund
against a payment — the most common manual path. Leaving it unmirrored would
reintroduce exactly the ledger drift that put credit notes in scope, so one
tightly-scoped `after_create_commit` that does nothing but enqueue is accepted.
It is the only decorator in the gem and must not grow.

### Jobs and idempotency

`app/jobs/spree/kashflow/{sync_order,sync_refund}_job.rb`

Both resolve the active integration from the record's store and no-op when there
is none. `SyncOrderJob` returns immediately if the order already carries a
`kashflow.invoice_number` metafield — this makes retries safe and prevents
double-booking when a reimbursement-driven refund fires both the subscriber and
the decorator.

`retry_on` transport errors. `discard_on` `AuthenticationError` after writing the
error metafield — retrying bad credentials forever only fills the queue.

### Sync state (metafields, no migrations)

| Record | Key | Meaning |
|---|---|---|
| Order | `kashflow.invoice_number` | Set once posted; the idempotency key |
| Order | `kashflow.customer_code` | Upserted customer reference |
| Order | `kashflow.synced_at` | Timestamp of successful post |
| Order | `kashflow.sync_error` | Last failure, cleared on success |
| Refund | `kashflow.credit_note_number` | Set once posted; idempotency key |

`Spree::Metafield` is a real table, so "everything that has not reached the
books" is an ordinary query. Whether `set_metafield` requires a
`MetafieldDefinition` to pre-exist must be confirmed during implementation; if it
does, the engine seeds the definitions on boot.

### Admin

`app/views/spree/admin/integrations/forms/_kashflow.html.erb` renders the two
preference fields, matching `spree-shipstation`'s partial. No runtime dependency
on `spree_admin` — the host app provides it, and the gem ships no other views.

### Registration

`config/initializers/spree.rb`, with the body wrapped in `after_initialize`:

```ruby
Rails.application.config.after_initialize do
  Rails.application.config.spree.integrations << Spree::Integrations::Kashflow
  Spree.subscribers << Spree::Kashflow::OrderCompletedSubscriber
  Spree.subscribers << Spree::Kashflow::ReimbursementSubscriber
end
```

The wrapper is load-bearing, and is the pattern `spree-shipstation` uses.
`spree_core` **assigns** `Rails.application.config.spree.integrations = []` inside
its own `config.after_initialize`; a bare `config/initializers` file runs during
engine initialization, before that, and would be silently clobbered. A spec
asserts the registration survives boot.

## Testing

RSpec against a dummy app via `spree_dev_tools`, as in `spree-fixed_amt_discount`.

- **Payload mappers (the bulk of the value), as pure units:** VAT-inclusive line
  mapping; an order spanning two tax categories at different rates; a discounted
  line naming its promotion; shipping as a line; multi-currency resolution and
  the raise when the currency is not enabled on the account.
- **Unit-rate rounding:** a line with quantity > 1 whose net total does not
  divide evenly into a whole number of currency units.
- **The correctness guard:** an order engineered so the assembled total diverges
  from the order total must raise and post nothing.
- **Client:** stubbed SOAP responses via webmock. Never a live call. Auth
  failure, API error and transport failure each map to the right error class.
- **Jobs:** idempotency (a second run posts nothing); no-op when the integration
  is inactive or absent; `AuthenticationError` writes `kashflow.sync_error` and
  discards; transport errors retry.
- **Triggers:** each of the three enqueues exactly once; a reimbursement-driven
  refund does not double-post.
- **Registration:** the integration is in
  `Rails.application.config.spree.integrations` after boot.

Live verification against the real KashFlow account is a release gate, not a test
— the account exists and the API is enabled, so the payload shapes must be
confirmed against it before this is called 1.0.

## Packaging and release

Repository `aypex-io/spree-kashflow`, public, MIT, mirroring
`spree-fixed_amt_discount` and `spree-bank_payments`: author `Aypex`,
`hello@aypex.io`, `rubygems_mfa_required`, CI plus tag-triggered trusted
publishing. Runtime dependencies `spree >= 5.6.0`, `spree_extension`, `savon`.

First release **0.1.0**. Gem name availability on RubyGems confirmed 2026-08-16
(`spree-kashflow` and `spree_kashflow` both unclaimed).

## WSDL findings (read 2026-08-16 from the live WSDL, 166 operations)

The field names below are taken from the WSDL itself, not from documentation or
the 2018 gem. They supersede any guess elsewhere in this document.

**Operations used**

| Purpose | Operation | Signature |
|---|---|---|
| Create customer | `InsertCustomer` | `(UserName, Password, custr: Customer)` |
| Create invoice | `InsertInvoice_TypeDefined` | `(UserName, Password, Inv_TD: Invoice_TypeDefined)` |
| Record payment | `InsertInvoicePayment` | `(UserName, Password, InvoicePayment: Payment)` |
| Enabled currencies | `GetCurrencies` | `(UserName, Password)` |
| Nominal codes | `GetNominalCodes` | `(UserName, Password)` |
| Bank accounts | `GetBankAccounts` | `(UserName, Password)` |

Prefer `InsertInvoice_TypeDefined` over `InsertInvoice`: the latter carries
`Lines` as `ArrayOfAnyType`, the former takes a properly typed structure.

**`Invoice` fields that matter:** `InvoiceNumber:int`, `InvoiceDate:dateTime`,
`DueDate:dateTime`, `CustomerID:int`, `CustomerReference:string`,
`CurrencyCode:string`, `ExchangeRate:decimal`, `Lines`, `NetAmount:decimal`,
`VATAmount:decimal`, `AmountPaid:decimal`.

**`InvoiceLine` fields:** `Quantity:decimal`, `Description:string`,
`Rate:decimal`, `ChargeType:int`, `VatRate:decimal`, `VatAmount:decimal`,
`ProductID:int`, `Sort:int`, `ValuesInCurrency:integer`.

Note `Rate` and `Quantity` are both `decimal` with no scale fixed in the schema,
which *softens* but does not remove the unit-rate rounding concern above — the
service may still round server-side, so the correctness guard stays.

**`Payment` fields:** `PayInvoice:int` (the invoice number), `PayDate:dateTime`,
`PayAmount:decimal`, `PayMethod:int`, `PayAccount:int`, `PayNote:string`.

**`Customer`** has 78 fields; the ones used are `Code`, `Name`, `Email`,
`Address1`–`Address4`, `Postcode`, `CountryCode`, `VATNumber`, `CurrencyID`,
`ContactFirstName`, `ContactLastName`. It also carries `EC:int` and
`OutsideEC:int` VAT-treatment flags, which are relevant to TKF's US/UK/EU markets
and should be set from the customer's country rather than left default.

**Credit notes.** There is **no** `InsertCreditNote` operation. KashFlow models a
credit note as an invoice with negative values; `applyCreditNoteToInvoice` exists
to link one to the invoice it credits. So `CreditNotePayload` builds a negative
invoice through the same `InsertInvoice_TypeDefined` path and then calls
`applyCreditNoteToInvoice` against the original invoice number stored in the
order's `kashflow.invoice_number` metafield.

## Open questions for implementation

1. Whether `set_metafield` requires a pre-existing `MetafieldDefinition`.
2. Whether KashFlow enforces API rate limits worth backing off from.
3. What `ValuesInCurrency` on `InvoiceLine` controls — whether line values are
   expressed in the invoice currency or the account's base currency. This must be
   settled before multi-currency invoices are posted, since getting it wrong
   mis-states every non-GBP invoice.

## Risks

- **Unverified payload shapes.** The SOAP field names come from documentation and
  a 2018 implementation, not from a live call. First contact with the real
  account will surface mismatches; the mapper unit tests will not.
- **A wrong invoice is worse than no invoice.** The correctness guard is the
  mitigation, and it should not be weakened to make a sync succeed.
- **The one decorator is a slope.** It exists because Spree publishes no
  `refund.created` event. If Spree adds one, delete the decorator.
