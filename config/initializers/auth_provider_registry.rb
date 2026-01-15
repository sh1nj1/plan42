Rails.application.config.auth_providers = []

# Helper to register providers
# Provider structure:
# {
#   key: :email, (symbol)
#   name: 'string', (translatable key or string)
#   partial_path: 'path/to/partial', (optional, for alternative login buttons)
#   priority: integer (lower is higher)
# }

# Register Email Provider (Default)
Rails.application.config.auth_providers << {
  key: :email,
  name: "auth.providers.email",
  priority: 0
}

# Register Google Provider (Pre-extraction)
Rails.application.config.auth_providers << {
  key: :google,
  name: "auth.providers.google",
  partial_path: "sessions/providers/google",
  priority: 10
}

# Register Passkey Provider (Pre-extraction)
Rails.application.config.auth_providers << {
  key: :passkey,
  name: "auth.providers.passkey",
  partial_path: "sessions/providers/passkey",
  priority: 20
}
