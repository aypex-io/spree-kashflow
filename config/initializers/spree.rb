# frozen_string_literal: true

# The after_initialize wrapper is load-bearing: spree_core ASSIGNS
# config.spree.integrations = [] inside its own after_initialize, which runs
# AFTER engine initializers and after config/initializers files. Registering at
# file scope here would be silently clobbered and the integration would never
# appear in the admin. spec/spree/kashflow/registration_spec.rb pins this.
Rails.application.config.after_initialize do
  Rails.application.config.spree.integrations << Spree::Integrations::Kashflow
end
