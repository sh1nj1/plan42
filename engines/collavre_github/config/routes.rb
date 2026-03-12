CollavreGithub::Engine.routes.draw do
  # API endpoints (OAuth token auth)
  namespace :api do
    resource :token, only: [ :show ], controller: "tokens"
  end

  # Webhook endpoint (public, no auth)
  # Both singular and plural for backward compatibility
  post "webhook", to: "webhooks#create", as: :webhook
  post "webhooks", to: "webhooks#create"

  # Account endpoints
  resource :account, only: [ :show ] do
    get :organizations
    get :repositories
  end

  # Creative integration endpoints
  resources :creatives, only: [] do
    resource :integration, module: :creatives, only: [ :show, :update, :destroy ]
  end
end
