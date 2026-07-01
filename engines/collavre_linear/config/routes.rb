CollavreLinear::Engine.routes.draw do
  # OAuth callback from Linear
  get  "auth/callback",      to: "auth#callback",       as: :auth_callback
  # Setup wizard after OAuth succeeds
  get  "auth/setup",         to: "auth#setup",          as: :setup_auth
  # Store creative_id in session before redirecting to Linear
  post "auth/store_creative", to: "auth#store_creative", as: :store_creative_auth
end
