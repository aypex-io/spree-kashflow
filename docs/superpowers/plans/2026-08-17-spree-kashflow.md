# spree-kashflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `spree-kashflow` 0.1.0 — a Spree 5.6 engine that pushes completed orders to KashFlow as invoices and refunds as credit notes, over the SOAP API, configured through Spree's Integrations framework.

**Architecture:** Core events (`order.completed`, `reimbursement.reimbursed`) plus one `Spree::Refund` decorator enqueue background jobs. Jobs resolve a per-store `Spree::Integrations::Kashflow`, build payloads with pure mapper objects, and post through a thin SOAP client. Sync state lives in metafields — no migrations, no install generator.

**Tech Stack:** Ruby >= 3.3, Rails engine, Spree >= 5.6.0, `savon` 2.17 for SOAP, RSpec via `spree_dev_tools`, webmock for HTTP stubbing, standardrb, YARD, GitHub Actions with RubyGems trusted publishing.

**Spec:** `docs/superpowers/specs/2026-08-16-spree-kashflow-design.md` — read it. The "WSDL findings" section carries the real field names and supersedes any guess.

**Reference:** `docs/kashflow-service.wsdl` is the live WSDL, vendored. Consult it rather than guessing a field name or operation signature.

## Global Constraints

- Spree floor **`>= 5.6.0`**; Ruby **`>= 3.3`**. Spree 5.6.1 in use.
- Gem `spree-kashflow`; require path `spree/kashflow`; constant `Spree::Kashflow`; `engine_name "spree_kashflow"` (no dash — it generates route helper prefixes).
- **Runtime deps in the gemspec** (`spree`, `spree_extension`, `savon`); **development deps in the Gemfile**. Do not put `spree_dev_tools` in the gemspec.
- **No migrations. No install generator.** State lives in metafields.
- **Exactly ONE decorator** in the gem: `Spree::Refund`, and it may only enqueue a job.
- `# frozen_string_literal: true` at the top of **every** Ruby file, no exceptions.
- **YARD on every public class and public method** (`##` block, blank line, tags, real Ruby types). Verify with `yard stats --list-undoc`.
- **TDD:** first red must be an **assertion** failure. A `NameError` is not red — add the empty class/method, re-run, show the assertion failing, then implement.
- **RSpec contract:** one behaviour and one expectation per example; present-tense names; no `should`; verifying doubles only (`instance_double`, `class_double`); prefer spies (`allow` then `expect(...).to have_received`); no named classes in specs (use `Class.new` + `stub_const`); **stub all HTTP — never a live SOAP call**.
- `Spree::Kashflow::Client` is the **only** file permitted to reference `Savon` or SOAP.
- The four numeric preferences ship **blank and required** — no defaults. A wrong nominal code silently mis-posts revenue.
- Never place a KashFlow call in a customer-facing request cycle.
- Licence MIT, author `Aypex`, `hello@aypex.io`, `rubygems_mfa_required` = `'true'`, version `0.1.0`.
- Commit after every task. Run `bundle exec standardrb` on changed files before each commit.

---

### Task 1: Scaffold the engine so an empty suite runs green

**Files:**
- Create: the gem skeleton via `rails plugin new`
- Create: `spree-kashflow.gemspec`, `Gemfile`, `Rakefile`, `.rspec`, `.gitignore`, `LICENSE`
- Create: `lib/spree-kashflow.rb`, `lib/spree/kashflow.rb`, `lib/spree/kashflow/version.rb`, `lib/spree/kashflow/engine.rb`
- Create: `.github/workflows/ci.yml`
- Test: `spec/spec_helper.rb`, `spec/spree/kashflow/version_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Spree::Kashflow::VERSION` (String), `Spree::Kashflow::Engine` (a `Rails::Engine`), and a bootable dummy app at `spec/dummy` for later tasks.

**Why `rails plugin new`:** this gem ships `app/` (models, jobs, presenters, views), so it is an engine. The `develop-ruby-gem` skill reserves `bundle gem` for plain and Railtie gems and requires an engine be generated, not hand-built.

- [ ] **Step 1: Generate the skeleton**

```bash
cd ~/Developer/spree-kashflow
rails plugin new . --full --skip-test --dummy-path=spec/dummy \
  --skip-active-storage --skip-action-mailbox --skip-action-text \
  --skip-javascript --skip-hotwire --force
```

`--full` (not `--mountable`) because Spree extensions add to the `Spree` namespace rather than mounting their own isolated routes. `--force` is safe: the directory currently contains only `docs/` and `.git/`.

The generator will produce `spree_kashflow.gemspec` or similar — you will replace it wholesale in Step 2, and rename any generated `lib/spree_kashflow*` paths to the `lib/spree/kashflow` layout in Step 3. Delete anything the generator created that this plan does not list (e.g. `app/assets/config/*.js` beyond the manifest, `MIT-LICENSE` if you add `LICENSE`, `bin/`).

- [ ] **Step 2: Write the gemspec**

`spree-kashflow.gemspec` — replace whatever the generator wrote:

```ruby
# frozen_string_literal: true

lib = File.expand_path('../lib/', __FILE__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require 'spree/kashflow/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'spree-kashflow'
  s.version     = Spree::Kashflow::VERSION
  s.summary     = 'KashFlow accounting integration for Spree'
  s.description = 'Pushes completed Spree orders to KashFlow as invoices and refunds as credit ' \
                  'notes over the KashFlow SOAP API, configured per store through Spree\'s ' \
                  'Integrations framework.'
  s.required_ruby_version = '>= 3.3'

  s.author   = 'Aypex'
  s.email    = 'hello@aypex.io'
  s.homepage = 'https://github.com/aypex-io/spree-kashflow'
  s.license  = 'MIT'

  s.metadata = {
    'source_code_uri' => s.homepage,
    'bug_tracker_uri' => "#{s.homepage}/issues",
    'changelog_uri' => "#{s.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  s.files = Dir['{app,config,lib}/**/*', 'LICENSE', 'Rakefile', 'README.md', 'CHANGELOG.md']
  s.require_path = 'lib'

  s.add_dependency 'savon', '~> 2.17'
  s.add_dependency 'spree', '>= 5.6.0'
  s.add_dependency 'spree_extension'
end
```

Development dependencies do NOT go here — they go in the Gemfile.

- [ ] **Step 3: Write the entry points, version and engine**

`lib/spree/kashflow/version.rb`:

```ruby
# frozen_string_literal: true

module Spree
  module Kashflow
    VERSION = '0.1.0'
  end
end
```

`lib/spree/kashflow/engine.rb`:

```ruby
# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Rails engine for the KashFlow integration.
    #
    # Loads the gem's +app/+ tree into the host application and applies the
    # gem's single decorator on each reload.
    #
    class Engine < ::Rails::Engine
      require 'spree/core'
      isolate_namespace Spree

      # Deliberately not "spree-kashflow": engine_name generates route helper
      # prefixes and must be a valid Ruby identifier, so it cannot contain a dash.
      engine_name 'spree_kashflow'

      config.generators do |g|
        g.test_framework :rspec
      end

      ##
      # Loads the gem's decorators. Called on every reload in development.
      #
      # @return [void]
      #
      def self.activate
        # Three levels up from lib/spree/kashflow/ to reach the gem root.
        Dir.glob(File.join(File.dirname(__FILE__), '../../../app/**/*_decorator*.rb')).sort.each do |c|
          Rails.configuration.cache_classes ? require(c) : load(c)
        end
      end

      config.to_prepare(&method(:activate).to_proc)
    end
  end
end
```

`lib/spree/kashflow.rb`:

```ruby
# frozen_string_literal: true

require 'spree/core'
require 'savon'
require 'spree/kashflow/version'
require 'spree/kashflow/engine'
```

`lib/spree-kashflow.rb`:

```ruby
# frozen_string_literal: true

# Bundler auto-requires a gem by its *name*, so `gem "spree-kashflow"` in a host
# Gemfile issues `require "spree-kashflow"`. The real entry point is
# `spree/kashflow` (matching the Spree::Kashflow namespace), so this shim keeps
# the default `Bundler.require` working.
require 'spree/kashflow'
```

- [ ] **Step 4: Write the Gemfile, Rakefile, .rspec and .gitignore**

`Gemfile`:

```ruby
# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'pg'
gem 'propshaft'

gem 'spree_admin'

group :development, :test do
  gem 'spree_dev_tools'
  gem 'standard'
  gem 'webmock'
  gem 'yard'
end

# spree_dev_tools depends on this transitively (for `assigns` in controller
# specs) but never requires it, and it is a Railtie -- requiring it after boot
# is too late to hook in. List it explicitly so Bundler.require pulls it in
# before Rails.application initializes.
group :test do
  gem 'rails-controller-testing'
end
```

`spree_admin` is a Gemfile entry only — the gem ships an admin form partial that `spree_admin` renders, but the host app owns that dependency, so it must NOT appear in the gemspec.

`Rakefile`:

```ruby
# frozen_string_literal: true

require 'bundler'
Bundler::GemHelper.install_tasks

require 'rspec/core/rake_task'
require 'spree/testing_support/extension_rake'

RSpec::Core::RakeTask.new

task default: :spec

desc 'Generates a dummy app for testing'
task :test_app do
  # Must be the require path, not the gem name -- spree_core's common:test_app
  # does a literal `require ENV['LIB_NAME']` and templates the same string into
  # the generated dummy app.
  ENV['LIB_NAME'] = 'spree/kashflow'
  ENV['DB'] ||= 'postgres'
  Rake::Task['extension:test_app'].execute(install_admin: true)
end
```

`install_admin: true` because the admin form partial is exercised in Task 9.

`.rspec`:

```
--color
-r spec_helper
-f documentation
```

`.gitignore` must include `spec/dummy/`, `pkg/`, `tmp/`, `log/`, `coverage/`, `.bundle/`, `Gemfile.lock`, `*.gem`, `.yardoc/`, `doc/`.

- [ ] **Step 5: Write the spec helper and version spec**

`spec/spec_helper.rb`:

```ruby
# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require File.expand_path('../dummy/config/environment.rb', __FILE__)
require 'spree_dev_tools/rspec/spec_helper'
require 'webmock/rspec'

# No spec may make a live SOAP call. WebMock blocks all outbound HTTP.
WebMock.disable_net_connect!(allow_localhost: true)

Dir[File.join(File.dirname(__FILE__), 'support/**/*.rb')].sort.each { |f| require f }
```

`spec/spree/kashflow/version_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::Kashflow do
  it 'exposes a semantic version string' do
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it 'loads its engine' do
    expect(defined?(Spree::Kashflow::Engine)).to eq('constant')
  end
end
```

- [ ] **Step 6: Write the CI workflow**

`.github/workflows/ci.yml` — same shape as `aypex-io/spree-fixed_amt_discount`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  tests:
    name: Tests
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: password
          POSTGRES_DB: spree_test
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    env:
      DB: postgres
      DATABASE_URL: postgres://postgres:password@localhost:5432/spree_test
      RAILS_ENV: test
      CI: true
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true
      - name: Install libvips
        run: sudo apt-get update && sudo apt-get install -y libvips
      - name: Create test app
        run: bundle exec rake test_app
      - name: Run specs
        run: bundle exec rspec --format progress

  lint:
    name: Standard
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true
      - run: bundle exec standardrb
```

- [ ] **Step 7: Build the dummy app and run the suite**

```bash
bundle install
bundle exec rake test_app
bundle exec rspec
bundle exec standardrb
```

Expected: dummy app generates (a "Skipping installation no generator to run..." line is EXPECTED — this gem ships no install generator by design), then 2 examples / 0 failures, and standardrb clean.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Scaffold spree-kashflow engine and spec harness"
```

---

### Task 2: The integration model, its registration and the admin form

**Files:**
- Create: `app/models/spree/integrations/kashflow.rb`
- Create: `app/views/spree/admin/integrations/forms/_kashflow.html.erb`
- Create: `config/locales/en.yml`
- Create: `config/initializers/spree.rb`
- Create: `app/assets/images/integration_icons/kashflow-logo.png` (any placeholder image is acceptable for now; note it in the report)
- Test: `spec/models/spree/integrations/kashflow_spec.rb`, `spec/spree/kashflow/registration_spec.rb`

**Interfaces:**
- Consumes: `Spree::Kashflow::Engine` from Task 1.
- Produces: `Spree::Integrations::Kashflow`, a `Spree::Integration` subclass with preferences `username` (string), `password` (password), `sales_nominal_code` (integer), `shipping_nominal_code` (integer), `bank_account_id` (integer), `payment_method_id` (integer). All six are required. Later tasks read them via `preferred_username` etc.

**Background — the registration trap:** `spree_core` **assigns** `Rails.application.config.spree.integrations = []` inside its own `config.after_initialize`. A bare `config/initializers/*.rb` file runs during engine initialization, *before* that, and would be silently clobbered — the integration would simply never appear in the admin, with no error. The body must therefore be wrapped in `after_initialize`. This is exactly what `spree-shipstation` does. The registration spec exists so it cannot regress unnoticed.

- [ ] **Step 1: Write the failing specs**

`spec/models/spree/integrations/kashflow_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::Integrations::Kashflow do
  subject(:integration) { described_class.new(store: Spree::Store.default) }

  it 'is grouped under accounting' do
    expect(described_class.integration_group).to eq('Accounting')
  end

  it 'requires a username' do
    integration.preferred_username = nil

    expect(integration).not_to be_valid
  end

  it 'requires a password' do
    integration.preferred_password = nil

    expect(integration).not_to be_valid
  end

  it 'requires a sales nominal code' do
    integration.preferred_sales_nominal_code = nil

    expect(integration).not_to be_valid
  end

  it 'requires a bank account' do
    integration.preferred_bank_account_id = nil

    expect(integration).not_to be_valid
  end

  it 'defaults the sales nominal code to blank so it must be chosen' do
    expect(described_class.new.preferred_sales_nominal_code).to be_nil
  end
end
```

`spec/spree/kashflow/registration_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'integration registration' do
  let(:registered) { Rails.application.config.spree.integrations }

  it 'registers the KashFlow integration' do
    expect(registered).to include(Spree::Integrations::Kashflow)
  end

  it 'registers it exactly once' do
    expect(registered.count(Spree::Integrations::Kashflow)).to eq(1)
  end
end
```

- [ ] **Step 2: Run the specs and confirm assertion-red**

Run: `bundle exec rspec spec/models/spree/integrations/kashflow_spec.rb`

The first failure will be `NameError: uninitialized constant Spree::Integrations::Kashflow`. **That is not red.** Create the empty class first:

```ruby
# frozen_string_literal: true

module Spree
  module Integrations
    class Kashflow < Spree::Integration
    end
  end
end
```

Re-run. The failures must now be assertion failures (`expected #<Kashflow> not to be valid`, `expected nil to eq "Accounting"`). Record that output in your report — that is the red this plan requires.

- [ ] **Step 3: Implement the integration model**

`app/models/spree/integrations/kashflow.rb`:

```ruby
# frozen_string_literal: true

module Spree
  module Integrations
    ##
    # Per-store KashFlow credentials and posting configuration.
    #
    # The four numeric preferences decide which ledger accounts money lands in and deliberately have no
    # defaults: a wrong nominal code silently posts revenue to the wrong place, so the integration cannot
    # be saved until an operator chooses them.
    #
    class Kashflow < Spree::Integration
      preference :username, :string
      preference :password, :password
      preference :sales_nominal_code, :integer
      preference :shipping_nominal_code, :integer
      preference :bank_account_id, :integer
      preference :payment_method_id, :integer

      validates :preferred_username, :preferred_password, presence: true
      validates :preferred_sales_nominal_code,
        :preferred_shipping_nominal_code,
        :preferred_bank_account_id,
        :preferred_payment_method_id,
        presence: true,
        numericality: {only_integer: true, greater_than: 0}

      ##
      # @return [String] the admin group this integration is listed under
      #
      def self.integration_group
        'Accounting'
      end

      ##
      # @return [String] path to the bundled logo, relative to the asset root
      #
      def self.icon_path
        'integration_icons/kashflow-logo.png'
      end

      ##
      # @return [String] the name shown in the admin
      #
      def self.integration_name
        Spree.t('admin.integrations.kashflow.brand_name')
      end

      ##
      # Verifies the stored credentials against the KashFlow API.
      #
      # @return [TrueClass, FalseClass] true when KashFlow accepts the credentials
      #
      def can_connect?
        client.verify_credentials
      rescue Spree::Kashflow::Error => e
        self.connection_error_message = e.message
        false
      end

      ##
      # @return [Spree::Kashflow::Client] a client bound to this integration's credentials
      #
      def client
        Spree::Kashflow::Client.new(username: preferred_username, password: preferred_password)
      end
    end
  end
end
```

> `can_connect?` and `client` reference `Spree::Kashflow::Client`, which Task 3 creates. The specs in THIS task do not exercise them, so they will not run before it exists. Do not stub the client here and do not build a placeholder for it.

`config/locales/en.yml`:

```yaml
en:
  spree:
    admin:
      integrations:
        kashflow:
          brand_name: "KashFlow"
          username: "API username"
          password: "API password"
          sales_nominal_code: "Sales nominal code"
          shipping_nominal_code: "Shipping nominal code"
          bank_account_id: "Bank account"
          payment_method_id: "Payment method"
```

`app/views/spree/admin/integrations/forms/_kashflow.html.erb` — mirror `spree-shipstation`'s partial:

```erb
<div class="row">
  <div class="col-12">
    <%= preference_field(@integration, form, 'username', i18n_scope: 'admin.integrations.kashflow') %>
    <%= preference_field(@integration, form, 'password', i18n_scope: 'admin.integrations.kashflow') %>
    <%= preference_field(@integration, form, 'sales_nominal_code', i18n_scope: 'admin.integrations.kashflow') %>
    <%= preference_field(@integration, form, 'shipping_nominal_code', i18n_scope: 'admin.integrations.kashflow') %>
    <%= preference_field(@integration, form, 'bank_account_id', i18n_scope: 'admin.integrations.kashflow') %>
    <%= preference_field(@integration, form, 'payment_method_id', i18n_scope: 'admin.integrations.kashflow') %>
  </div>
</div>
```

Task 9 replaces the four numeric fields with dropdowns fetched from the account. Plain fields here keep this task independently shippable.

`config/initializers/spree.rb`:

```ruby
# frozen_string_literal: true

# The after_initialize wrapper is load-bearing: spree_core ASSIGNS
# config.spree.integrations = [] inside its own after_initialize, which runs
# AFTER engine initializers and after config/initializers files. Registering at
# file scope here would be silently clobbered and the integration would never
# appear in the admin. spec/spree/kashflow/registration_spec.rb pins this.
Rails.application.config.after_initialize do
  Rails.application.config.spree.integrations << Spree::Integrations::Kashflow
end
```

- [ ] **Step 4: Run the specs**

Run: `bundle exec rspec spec/models/spree/integrations/kashflow_spec.rb spec/spree/kashflow/registration_spec.rb`

Expected: PASS, 8 examples, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app config spec
bundle exec standardrb
git add -A
git commit -m "Add the KashFlow integration model, registration and admin form"
```

---

### Task 3: The SOAP client

**Files:**
- Create: `lib/spree/kashflow/errors.rb`
- Create: `lib/spree/kashflow/client.rb`
- Modify: `lib/spree/kashflow.rb` (require both)
- Test: `spec/spree/kashflow/client_spec.rb`, `spec/support/kashflow_soap.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Spree::Kashflow::Error` < `StandardError`, with subclasses `AuthenticationError`, `ApiError`, `TransportError`.
  - `Spree::Kashflow::Client.new(username:, password:)` exposing:
    - `#verify_credentials` → `TrueClass, FalseClass`
    - `#currencies` → `Array<Hash>` of `{code: String, id: Integer}`
    - `#nominal_codes` → `Array<Hash>` of `{id: Integer, name: String}`
    - `#bank_accounts` → `Array<Hash>` of `{id: Integer, name: String}`
    - `#upsert_customer(payload)` → `Integer` customer id
    - `#create_invoice(payload)` → `Integer` invoice number
    - `#record_invoice_payment(payload)` → `TrueClass`
    - `#apply_credit_note(credit_note_number:, invoice_number:)` → `TrueClass`

**Background:** this is the only file in the gem permitted to reference `Savon` or SOAP. Every method returns plain Ruby — no savon object crosses the boundary. KashFlow sends `UserName`/`Password` on **every** call with no session token, so the client is stateless and caches nothing. Operation signatures are in `docs/kashflow-service.wsdl` and summarised in the spec's "WSDL findings".

- [ ] **Step 1: Write the SOAP stub helper**

`spec/support/kashflow_soap.rb`:

```ruby
# frozen_string_literal: true

module KashflowSoap
  WSDL_URL = 'https://securedwebapp.com/api/service.asmx?WSDL'
  ENDPOINT = 'https://securedwebapp.com/api/service.asmx'

  ##
  # Stubs the WSDL fetch with the vendored copy so no spec reaches the network.
  #
  # @return [void]
  #
  def stub_kashflow_wsdl
    stub_request(:get, WSDL_URL).to_return(
      status: 200,
      body: Rails.root.join('../../docs/kashflow-service.wsdl').read,
      headers: {'Content-Type' => 'text/xml'}
    )
  end

  ##
  # Stubs a SOAP operation with a canned response body.
  #
  # @param body [String] the inner XML of the SOAP body
  # @param status [Integer] HTTP status to return
  # @return [void]
  #
  def stub_kashflow_call(body, status: 200)
    stub_request(:post, ENDPOINT).to_return(
      status: status,
      body: <<~XML,
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>#{body}</soap:Body>
        </soap:Envelope>
      XML
      headers: {'Content-Type' => 'text/xml; charset=utf-8'}
    )
  end
end

RSpec.configure { |config| config.include KashflowSoap }
```

> The path to the vendored WSDL is relative to the dummy app's root. If `Rails.root.join('../../docs/kashflow-service.wsdl')` does not resolve, compute it from `__dir__` instead — adapt the path, not the approach.

- [ ] **Step 2: Write the failing specs**

`spec/spree/kashflow/client_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::Kashflow::Client do
  subject(:client) { described_class.new(username: 'user', password: 'secret') }

  before { stub_kashflow_wsdl }

  describe '#verify_credentials' do
    it 'returns true when KashFlow accepts the credentials' do
      stub_kashflow_call('<GetCurrenciesResponse xmlns="KashFlowAPI"><GetCurrenciesResult /></GetCurrenciesResponse>')

      expect(client.verify_credentials).to be(true)
    end
  end

  describe '#create_invoice' do
    it 'returns the invoice number KashFlow assigned' do
      stub_kashflow_call(
        '<InsertInvoice_TypeDefinedResponse xmlns="KashFlowAPI">' \
        '<InsertInvoice_TypeDefinedResult>4471</InsertInvoice_TypeDefinedResult>' \
        '</InsertInvoice_TypeDefinedResponse>'
      )

      expect(client.create_invoice({'CustomerID' => 1})).to eq(4471)
    end
  end

  describe 'error mapping' do
    it 'raises AuthenticationError when KashFlow rejects the credentials' do
      stub_kashflow_call(
        '<soap:Fault><faultcode>soap:Server</faultcode>' \
        '<faultstring>Invalid username or password</faultstring></soap:Fault>',
        status: 500
      )

      expect { client.verify_credentials }.to raise_error(Spree::Kashflow::AuthenticationError)
    end

    it 'raises ApiError for other SOAP faults' do
      stub_kashflow_call(
        '<soap:Fault><faultcode>soap:Server</faultcode>' \
        '<faultstring>Nominal code does not exist</faultstring></soap:Fault>',
        status: 500
      )

      expect { client.create_invoice({}) }.to raise_error(Spree::Kashflow::ApiError)
    end

    it 'raises TransportError when the connection fails' do
      stub_request(:post, KashflowSoap::ENDPOINT).to_timeout

      expect { client.create_invoice({}) }.to raise_error(Spree::Kashflow::TransportError)
    end
  end
end
```

- [ ] **Step 3: Confirm assertion-red**

Run: `bundle exec rspec spec/spree/kashflow/client_spec.rb`

`NameError` is not red. Create `lib/spree/kashflow/errors.rb` with the four error classes and `lib/spree/kashflow/client.rb` with an empty `Client` class taking the keywords, require both from `lib/spree/kashflow.rb`, re-run, and record the assertion failures (`NoMethodError: undefined method 'verify_credentials'` is acceptable as the second red for a method that does not exist yet — add the empty method so the failure becomes the assertion).

- [ ] **Step 4: Implement the errors**

`lib/spree/kashflow/errors.rb`:

```ruby
# frozen_string_literal: true

module Spree
  module Kashflow
    ##
    # Base class for every error this gem raises.
    #
    class Error < StandardError; end

    ##
    # Raised when KashFlow rejects the configured credentials. Not retryable.
    #
    class AuthenticationError < Error; end

    ##
    # Raised when KashFlow accepts the request but refuses the operation.
    #
    class ApiError < Error; end

    ##
    # Raised when the KashFlow service could not be reached. Retryable.
    #
    class TransportError < Error; end
  end
end
```

- [ ] **Step 5: Implement the client**

`lib/spree/kashflow/client.rb`. Requirements, all load-bearing:

- `WSDL = 'https://securedwebapp.com/api/service.asmx?WSDL'`.
- A private `call(operation, message = {})` that merges `{'UserName' => @username, 'Password' => @password}` into every message, invokes `savon_client.call(operation, message: ...)`, and returns `response.body`.
- `call` rescues `Savon::SOAPFault` and maps it: if the fault string matches `/invalid.*(username|password)|not authori[sz]ed/i` raise `AuthenticationError`, otherwise `ApiError`. It rescues `Savon::HTTPError`, `HTTPI::SSLError` and `Errno::ECONNREFUSED`, `Net::OpenTimeout`, `Net::ReadTimeout` as `TransportError`. Every raise carries the fault string as its message.
- `verify_credentials` calls `:get_currencies` and returns `true`; it does not rescue — the caller decides.
- `create_invoice(payload)` calls `:insert_invoice_type_defined` with `{'Inv_TD' => payload}` and returns the result as an `Integer`.
- `upsert_customer(payload)` calls `:insert_customer` with `{'custr' => payload}` and returns the customer id as an `Integer`.
- `record_invoice_payment(payload)` calls `:insert_invoice_payment` with `{'InvoicePayment' => payload}` and returns `true`.
- `apply_credit_note(credit_note_number:, invoice_number:)` calls `:apply_credit_note_to_invoice` and returns `true`.
- `currencies`, `nominal_codes`, `bank_accounts` call `:get_currencies`, `:get_nominal_codes`, `:get_bank_accounts` and each normalise the response into an `Array<Hash>` with symbol keys, returning `[]` when the response carries no rows. **Consult `docs/kashflow-service.wsdl` for the exact response element names** rather than guessing.
- Savon is configured with `log: false` and `convert_response_tags_to: ->(tag) { tag }` so response keys are not mangled.
- Every public method carries a YARD block with `@param`, `@return` and `@raise` tags.

- [ ] **Step 6: Run the specs**

Run: `bundle exec rspec spec/spree/kashflow/client_spec.rb`

Expected: PASS, 5 examples, 0 failures. If a stubbed response shape does not match what savon parses, fix the STUB to match reality, never the assertion.

- [ ] **Step 7: Lint, document and commit**

```bash
bundle exec standardrb --fix lib spec
bundle exec standardrb
bundle exec yard stats --list-undoc
git add -A
git commit -m "Add the KashFlow SOAP client and error hierarchy"
```

`yard stats --list-undoc` must report no undocumented public methods in `lib/spree/kashflow/client.rb` or `errors.rb`.

---

### Task 4: The customer payload mapper

**Files:**
- Create: `app/presenters/spree/kashflow/customer_payload.rb`
- Test: `spec/presenters/spree/kashflow/customer_payload_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure object).
- Produces: `Spree::Kashflow::CustomerPayload.new(order)` with `#to_h` → `Hash` with String keys matching the WSDL `Customer` type.

**Background:** pure object — Active Record in, Hash out, no network. Field names come from the WSDL `Customer` type (78 fields; only these are used): `Code`, `Name`, `Email`, `Address1`–`Address4`, `Postcode`, `CountryCode`, `VATNumber`, `ContactFirstName`, `ContactLastName`, `EC`, `OutsideEC`.

`EC` and `OutsideEC` are VAT-treatment flags and matter for TKF's US/UK/EU markets: set `EC` to 1 when the billing country is in the EU and is not the store's own country, `OutsideEC` to 1 when the country is outside both the UK and the EU, and both to 0 for domestic. Derive the EU membership list from a frozen constant in the class; do not add a dependency for it.

`Code` is the KashFlow customer reference and must be stable and unique per customer — use the order's email address, which is present on both guest and account orders.

- [ ] **Step 1: Write the failing specs**

Cover, one expectation each: maps the billing address into `Address1`–`Address4`/`Postcode`/`CountryCode`; uses the order email as both `Email` and `Code`; splits the billing name into `ContactFirstName`/`ContactLastName`; sets `EC`/`OutsideEC` to 0/0 for a domestic order; sets `EC` to 1 for an EU order; sets `OutsideEC` to 1 for a US order; includes `VATNumber` when the order has one and omits the key when it does not.

Build orders with `build_stubbed` where persistence is not the point.

- [ ] **Step 2: Confirm assertion-red, then implement**

Empty class first, then implement. Full YARD on the class and `#to_h`.

- [ ] **Step 3: Run, lint, document, commit**

```bash
bundle exec rspec spec/presenters/spree/kashflow/customer_payload_spec.rb
bundle exec standardrb --fix app spec && bundle exec standardrb
bundle exec yard stats --list-undoc
git add -A && git commit -m "Add the KashFlow customer payload mapper"
```

---

### Task 5: The invoice payload mapper and the correctness guard

This is the task that carries the money arithmetic. It is the most important task in the plan.

**Files:**
- Create: `app/presenters/spree/kashflow/invoice_payload.rb`
- Modify: `lib/spree/kashflow/errors.rb` (add `TotalMismatchError`)
- Test: `spec/presenters/spree/kashflow/invoice_payload_spec.rb`

**Interfaces:**
- Consumes: `Spree::Integrations::Kashflow` (Task 2) for the nominal codes.
- Produces:
  - `Spree::Kashflow::InvoicePayload.new(order, integration:)` with `#to_h` → `Hash`, and `#lines` → `Array<Hash>`.
  - `Spree::Kashflow::TotalMismatchError` < `Spree::Kashflow::Error`.

**Background — the arithmetic.** TKF is VAT-inclusive; KashFlow wants net rates. Per Spree line item:

```
discounted_gross = line_item.amount + line_item.promo_total   # amount is pre-discount; promo_total is negative
net_total        = discounted_gross - line_item.included_tax_total
Rate             = (net_total / quantity).round(4)
VatAmount        = line_item.included_tax_total
VatRate          = net_total.zero? ? 0 : (included_tax_total / net_total * 100).round(2)
ChargeType       = integration.preferred_sales_nominal_code
Description      = "<product name>" or "<product name> (<codes> applied)" when promotions apply
```

Shipping becomes one additional line on the same basis, using `preferred_shipping_nominal_code`.

**Rate is a per-unit figure**, so `Rate * Quantity` need not equal `net_total`. Four decimal places is enough for realistic quantities (net 10.00 over qty 3 → 3.3333 × 3 = 9.9999, which rounds to 10.00), but it is not guaranteed, and that is precisely the failure mode that produced a surcharge bug in the sibling gem `spree-fixed_amt_discount` — a per-unit rounding that looks harmless until multiplied back up. So:

**The guard.** `#to_h` must, before returning:
1. For each line, assert `(Rate * Quantity).round(2) == net_total.round(2)`.
2. Assert `lines.sum { (Rate * Quantity).round(2) + VatAmount } == order.total`.

On any failure raise `TotalMismatchError` naming the offending line and both figures. **Post nothing.** A failed sync is a queryable flag; a wrong invoice is a discrepancy someone finds at year end.

**Currency.** `CurrencyCode` is `order.currency`. The caller (Task 7) is responsible for checking the currency is enabled on the account; this mapper only sets the field.

- [ ] **Step 1: Write the failing specs**

Cover, one expectation each:

- one line per Spree line item, plus one shipping line
- `Rate` is net of both VAT and discount for a VAT-inclusive line
- `VatAmount` equals the line's `included_tax_total`
- `VatRate` is 20 for a 20%-inclusive line and 5 for a 5%-inclusive line **in the same order** (mixed tax categories — the case an order-level adjustment cannot represent)
- the description names the promotion when one applies, and does not when none does
- `CurrencyCode` is the order's currency
- `ChargeType` is the sales nominal code on product lines and the shipping nominal code on the shipping line
- a line of quantity 3 whose net total is 10.00 produces `Rate` 3.3333 and still passes the guard
- **an order engineered so a line's `Rate * Quantity` cannot reconcile raises `TotalMismatchError` and returns no payload**
- **an order whose assembled total diverges from `order.total` raises `TotalMismatchError`**

Use real persisted orders with real tax rates for the tax examples — mirror the setup in `spree-fixed_amt_discount`'s `spec/integration/fixed_amount_promotion_tax_spec.rb`, which uses `create(:global_zone)`, two `create(:tax_category)` records and two `create(:tax_rate, included_in_price: true)` at 0.20 and 0.05.

- [ ] **Step 2: Confirm assertion-red, then implement**

Empty class first. Full YARD on the class, `#to_h`, `#lines`, and the guard method.

- [ ] **Step 3: Run, lint, document, commit**

```bash
bundle exec rspec spec/presenters/spree/kashflow/invoice_payload_spec.rb
bundle exec standardrb --fix app lib spec && bundle exec standardrb
bundle exec yard stats --list-undoc
git add -A && git commit -m "Add the KashFlow invoice payload mapper and total correctness guard"
```

---

### Task 6: The credit note payload mapper

**Files:**
- Create: `app/presenters/spree/kashflow/credit_note_payload.rb`
- Test: `spec/presenters/spree/kashflow/credit_note_payload_spec.rb`

**Interfaces:**
- Consumes: `Spree::Kashflow::InvoicePayload` (Task 5) — reuse its line-building rather than duplicating the arithmetic.
- Produces: `Spree::Kashflow::CreditNotePayload.new(refund, integration:)` with `#to_h` → `Hash`.

**Background:** KashFlow has **no** `InsertCreditNote` operation — verified against the WSDL. A credit note is an invoice with **negative** values, posted through the same `InsertInvoice_TypeDefined` path, then linked to the original with `applyCreditNoteToInvoice`.

A `Spree::Refund` may be partial, so the credit note is not simply the inverse of the invoice. For v0.1.0: a refund equal to the order total produces a full negative mirror of the invoice's lines; a partial refund produces a **single** negative line for the refunded amount, using the sales nominal code, with the description naming the refund reason. Splitting a partial refund back across lines and VAT rates is not attempted — there is no information in Spree tying a partial refund to specific line items, and inventing an apportionment would put arbitrary numbers in the ledger.

VAT on a partial refund line is apportioned at the order's blended rate: `order.included_tax_total / (order.total - order.included_tax_total)`. Document this in the class YARD as an approximation, and note it in the README.

- [ ] **Step 1: Write the failing specs**

Cover: a full refund mirrors the invoice lines with negated `Rate` and `VatAmount`; a partial refund produces exactly one line; the partial line's amount is negative and equals the refund amount; `CustomerReference` carries the original invoice number; the description names the refund reason.

- [ ] **Step 2: Confirm assertion-red, then implement. Step 3: Run, lint, document, commit.**

```bash
git commit -m "Add the KashFlow credit note payload mapper"
```

---

### Task 7: The sync jobs, metafields and idempotency

**Files:**
- Create: `app/jobs/spree/kashflow/sync_order_job.rb`, `app/jobs/spree/kashflow/sync_refund_job.rb`
- Create: `lib/spree/kashflow/metafields.rb`
- Test: `spec/jobs/spree/kashflow/sync_order_job_spec.rb`, `spec/jobs/spree/kashflow/sync_refund_job_spec.rb`

**Interfaces:**
- Consumes: `Client` (Task 3), `CustomerPayload` (4), `InvoicePayload` (5), `CreditNotePayload` (6), `Spree::Integrations::Kashflow` (2).
- Produces: `Spree::Kashflow::SyncOrderJob.perform_later(order_id)` and `Spree::Kashflow::SyncRefundJob.perform_later(refund_id)`. Metafield key constants in `Spree::Kashflow::Metafields`.

**Metafield keys** (constants, not string literals at call sites):

| Record | Key | Meaning |
|---|---|---|
| Order | `kashflow.invoice_number` | Idempotency key; set once posted |
| Order | `kashflow.customer_code` | Upserted customer reference |
| Order | `kashflow.synced_at` | Timestamp of successful post |
| Order | `kashflow.sync_error` | Last failure; cleared on success |
| Refund | `kashflow.credit_note_number` | Idempotency key |

**`SyncOrderJob#perform(order_id)`:**

1. Load the order; return if missing.
2. Resolve `Spree::Integrations::Kashflow` active for `order.store`; **return silently if absent or inactive**.
3. **Return immediately if the order already has a `kashflow.invoice_number` metafield.** This is what makes retries safe and prevents double-booking.
4. Assert `order.currency` is in `client.currencies`; raise `ApiError` naming the currency if not — booking a USD order as GBP is worse than not booking it.
5. `upsert_customer` → store `kashflow.customer_code`.
6. `create_invoice(InvoicePayload...)` → store `kashflow.invoice_number`.
7. If the order is paid, `record_invoice_payment` using `preferred_bank_account_id` and `preferred_payment_method_id`.
8. Set `kashflow.synced_at`; clear `kashflow.sync_error`.
9. On `Spree::Kashflow::Error`: write the message to `kashflow.sync_error` and re-raise.

`retry_on Spree::Kashflow::TransportError, wait: :polynomially_longer, attempts: 5`
`discard_on Spree::Kashflow::AuthenticationError` — retrying bad credentials forever only fills the queue; the error metafield is written before the discard.

**`SyncRefundJob#perform(refund_id)`** mirrors this: no-op if the refund already has `kashflow.credit_note_number`; requires the order to have an invoice number (re-enqueue via `TransportError` semantics is wrong here — if the invoice is not yet posted, raise `ApiError` so it surfaces); posts the negative invoice; then `apply_credit_note`.

**Whether `set_metafield` requires a pre-existing `MetafieldDefinition` is an open question** (spec, Open Questions §1). Determine it in this task by trying it in the dummy app. If a definition is required, create them in the engine's `after_initialize` and say so in your report.

- [ ] **Step 1: Write the failing specs**

Cover, one expectation each: posts an invoice and stores the number; **a second run posts nothing** (verify with a spy: `expect(client).to have_received(:create_invoice).once`); no-op when no integration exists; no-op when the integration is inactive; records a payment for a paid order; does not record a payment for an unpaid order; raises when the currency is not enabled; writes `kashflow.sync_error` on `ApiError`; discards on `AuthenticationError` after writing the error.

Use `instance_double(Spree::Kashflow::Client)` and `allow(Spree::Kashflow::Client).to receive(:new).and_return(client)`. No HTTP.

- [ ] **Step 2: Confirm assertion-red, then implement. Step 3: Run, lint, document, commit.**

```bash
git commit -m "Add the KashFlow sync jobs with metafield-backed idempotency"
```

---

### Task 8: Triggers — two subscribers and the one decorator

**Files:**
- Create: `app/subscribers/spree/kashflow/order_completed_subscriber.rb`, `app/subscribers/spree/kashflow/reimbursement_subscriber.rb`
- Create: `app/models/spree/refund_decorator.rb`
- Modify: `config/initializers/spree.rb` (register the subscribers)
- Test: `spec/subscribers/...`, `spec/models/spree/refund_decorator_spec.rb`

**Interfaces:**
- Consumes: the jobs from Task 7.
- Produces: no new public API; three enqueue paths.

**Background:** Spree 5.6 publishes `order.completed` and `reimbursement.reimbursed`, but **no `refund.created`**. The returns flow does not cover an admin issuing an ad-hoc refund against a payment — the most common manual path — so one `after_create_commit` decorator on `Spree::Refund` covers it. That decorator is the **only** one in this gem, it may do nothing but enqueue, and it must not grow. If Spree ever adds a `refund.created` event, delete it.

Subscribers follow the pattern in the host app's `backend/CLAUDE.md`: subclass `Spree::Subscriber`, `subscribes_to 'order.completed'`, resolve the record via `Spree::Order.find_by_prefix_id(event.payload['id'])`, enqueue, return.

Register both in the existing `after_initialize` block:

```ruby
Spree.subscribers << Spree::Kashflow::OrderCompletedSubscriber
Spree.subscribers << Spree::Kashflow::ReimbursementSubscriber
```

- [ ] **Step 1: Write the failing specs**

Cover: completing an order enqueues `SyncOrderJob` exactly once; a reimbursement enqueues `SyncRefundJob`; creating a `Spree::Refund` enqueues `SyncRefundJob`; **a reimbursement-driven refund does not enqueue twice for the same refund** (or, if it does enqueue twice, the job's idempotency makes it harmless — assert the harmless outcome explicitly, do not leave it untested); both subscribers are registered in `Spree.subscribers` after boot.

Use `have_enqueued_job` with `ActiveJob::TestHelper`.

- [ ] **Step 2: Confirm assertion-red, then implement. Step 3: Run, lint, document, commit.**

```bash
git commit -m "Add order, reimbursement and refund sync triggers"
```

---

### Task 9: Admin dropdowns for the nominal codes and bank account

**Files:**
- Modify: `app/views/spree/admin/integrations/forms/_kashflow.html.erb`
- Modify: `app/models/spree/integrations/kashflow.rb` (add the lookup helpers)
- Test: `spec/models/spree/integrations/kashflow_spec.rb` (extend)

**Interfaces:**
- Consumes: `Client#nominal_codes`, `Client#bank_accounts` (Task 3).
- Produces: `Spree::Integrations::Kashflow#nominal_code_options` and `#bank_account_options`, each `Array<Array(String, Integer)>` suitable for `options_for_select`, and each returning `[]` when credentials are absent or the lookup fails.

**Background:** these four preferences decide which ledger accounts real revenue posts to. Free-text integers are an invitation to mis-post, and `GetNominalCodes` / `GetBankAccounts` both exist, so the form offers what the connected account actually has.

The lookups must **degrade gracefully**: an admin opening the form before entering credentials, or while KashFlow is down, must see the form — not a 500. Return `[]` and let the field render empty with the validation message.

- [ ] **Step 1: Write the failing specs**

Cover: returns options when the client responds; returns `[]` when credentials are blank (and does not call the client); returns `[]` when the client raises `TransportError`.

- [ ] **Step 2: Confirm assertion-red, then implement. Step 3: Run, lint, document, commit.**

```bash
git commit -m "Populate the nominal code and bank account fields from the connected account"
```

---

### Task 10: README, CHANGELOG and release workflow

**Files:**
- Create: `README.md`, `CHANGELOG.md`, `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `Spree::Kashflow::VERSION`.
- Produces: the tag-triggered publish workflow Task 11 relies on.

The README must cover, in order:

1. What it does — completed orders become KashFlow invoices; refunds become credit notes.
2. Why SOAP and not REST, in two sentences, linking the vendor's own production disclaimer. Readers will ask.
3. Installation: `bundle add spree-kashflow`; requires Spree >= 5.6 and Ruby >= 3.3; no migrations and no generator to run.
4. Configuration: Integrations → KashFlow; API username and password (**note the KashFlow API password is often not the login password, and the SOAP API must be enabled on the account**); then the four ledger fields, which populate from the connected account.
5. Behaviour: what triggers a sync; that syncs are idempotent; that a sync never blocks checkout.
6. **The correctness guard** — the integration refuses to post an invoice whose assembled total does not match the order total, and records the failure rather than booking wrong numbers. State this plainly; it is a feature.
7. Known limitations: a partial refund posts as a single line at the order's blended VAT rate rather than apportioned across the original lines; `ValuesInCurrency` behaviour is unverified against a live multi-currency account.
8. Troubleshooting: how to find orders that failed to sync (query the `kashflow.sync_error` metafield).
9. Development: `bundle install`, `bundle exec rake test_app`, `bundle exec rspec`, `bundle exec standardrb`.
10. Licence: MIT.

No badges for services that are not set up.

`CHANGELOG.md`:

```markdown
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
```

`.github/workflows/release.yml`: copy from `aypex-io/spree-fixed_amt_discount` verbatim, changing only the repository name in the trusted-publisher comment block. Keep `environment: release`.

- [ ] **Verify:** `gem build spree-kashflow.gemspec` reports 0.1.0 with no warnings, then `rm -f spree-kashflow-0.1.0.gem`. `bundle exec rspec` fully green. `bundle exec standardrb` clean. `bundle exec yard stats --list-undoc` reports no undocumented public API.

- [ ] **Commit:** `git commit -m "Add README, CHANGELOG and release workflow"`

---

### Task 11: Publish

**Files:** none — repository and registry operations.

**This task needs the user.** Creating a public repository, registering a trusted publisher, and pushing a release tag are outward-facing. Stop and confirm before Steps 1, 3 and 4.

- [ ] **Step 1 (confirm first): create the repository**

```bash
gh repo create aypex-io/spree-kashflow \
  --public \
  --description "KashFlow accounting integration for Spree — orders become invoices, refunds become credit notes" \
  --source . --remote origin --push
```

- [ ] **Step 2: confirm CI green** — `gh run watch`. Both the `Tests` and `Standard` jobs must pass.

- [ ] **Step 3: create the `release` environment**

```bash
gh api -X PUT repos/aypex-io/spree-kashflow/environments/release
```

- [ ] **Step 4 (user action): register the RubyGems trusted publisher**

At <https://rubygems.org/profile/oidc/pending_trusted_publishers/new>: gem `spree-kashflow`, owner `aypex-io`, repository `spree-kashflow`, workflow `release.yml`, environment `release`. This must exist before the tag or the release fails at the OIDC exchange.

- [ ] **Step 5 (confirm first): tag and push**

```bash
git tag v0.1.0 && git push origin v0.1.0 && gh run watch
```

- [ ] **Step 6: verify** — `curl -s -o /dev/null -w "%{http_code}\n" https://rubygems.org/api/v1/gems/spree-kashflow.json` returns `200`.

- [ ] **Step 7: report** the published version and both URLs.

---

## Post-release: live verification (not a task)

Every payload shape in this plan comes from the WSDL, not from a live call. Before this is trusted with real books:

1. Configure the integration against the real KashFlow account in **staging**.
2. Complete one order and confirm the invoice in KashFlow — check the nominal code, the VAT breakdown per line, and the currency.
3. Refund it and confirm the credit note is linked to that invoice.
4. Settle the `ValuesInCurrency` question with a non-GBP order.

Only then promote to production.
