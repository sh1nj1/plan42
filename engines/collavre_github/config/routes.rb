CollavreGithub::Engine.routes.draw do
  # Webhook endpoint (public, no auth).
  #
  # The singular `webhook` alias was removed: repos accumulated a hook on each
  # spelling, and GitHub delivered every event to both. WebhookProvisioner now
  # deletes any leftover hook still pointing at the singular path.
  post "webhooks", to: "webhooks#create"

  # OAuth setup flow (popup wizard after callback)
  get "auth/setup", to: "auth#setup", as: :setup_auth
  post "auth/store_creative", to: "auth#store_creative", as: :store_creative_auth

  # Account endpoints
  resource :account, only: [ :show ] do
    get :organizations
    get :repositories
  end

  # Creative integration endpoints
  resources :creatives, only: [] do
    resource :integration, module: :creatives, only: [ :show, :update, :destroy ] do
      post :resync, on: :member
    end
  end
end
