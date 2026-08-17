# frozen_string_literal: true

# The after_initialize wrapper is load-bearing: spree_core ASSIGNS
# config.spree.integrations = [] inside its own after_initialize, which runs
# AFTER engine initializers and after config/initializers files. Registering at
# file scope here would be silently clobbered and the integration would never
# appear in the admin. spec/spree/kashflow/registration_spec.rb pins this.
#
# The two subscriber registrations live in this same block for consistency
# with that rule, even though Spree.subscribers itself is only ever
# concatenated onto (never reassigned) after it is first set.
Rails.application.config.after_initialize do
  Rails.application.config.spree.integrations << Spree::Integrations::Kashflow

  Spree.subscribers << Spree::Kashflow::OrderCompletedSubscriber
  Spree.subscribers << Spree::Kashflow::ReimbursementSubscriber
end
