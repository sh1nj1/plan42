CollavreLinear::Engine.routes.draw do
  # OAuth callback from Linear
  get  "auth/callback",      to: "auth#callback",       as: :auth_callback
  # Setup wizard after OAuth succeeds
  get  "auth/setup",         to: "auth#setup",          as: :setup_auth
  # Store creative_id in session before redirecting to Linear
  post "auth/store_creative", to: "auth#store_creative", as: :store_creative_auth

  # Inbound webhook from Linear (HMAC-signed, machine-to-machine, no user session)
  post "webhook", to: "webhooks#create", as: :webhook

  # Creative integration endpoints (link / unlink / resync)
  resources :creatives, only: [] do
    resource :integration, module: :creatives, only: [ :create, :destroy ] do
      post :resync, on: :member
      # Store the signing secret the admin pasted from Linear's webhook settings.
      post :secret, on: :member, action: :update_secret
      # Teams/projects for the link picker (populated as dropdowns in the modal).
      get :options, on: :member
    end
  end
end
