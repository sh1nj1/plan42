CollavreGithub::Engine.routes.draw do
  # Webhook endpoint (public, no auth).
  post "webhooks", to: "webhooks#create"

  # Deprecated singular alias, kept only until no repository points a hook at
  # it. Repos provisioned before the plural path existed still target this URL,
  # and nothing migrates them at deploy time — `WebhookProvisioner` deletes such
  # hooks, but only for repositories it happens to touch when an integration is
  # saved or `pr_monitor` runs. Dropping the route outright would 404 every
  # untouched repository's hook and silently stop its events.
  #
  # Serving both spellings no longer duplicates anything: a repo carrying a hook
  # on each receives the same X-GitHub-Delivery GUID twice and the second is
  # discarded by the idempotency ledger.
  post "webhook", to: "webhooks#create", as: :webhook

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
