# frozen_string_literal: true

module CollavreGithub
  module Tools
    # Kept as an alias of the core engine's shared error so existing rescue
    # blocks and tests in collavre_github continue to match. New code should
    # reference `Collavre::Tools::PermissionDeniedError` directly.
    PermissionDeniedError = ::Collavre::Tools::PermissionDeniedError
  end
end
