CollavreGithub::Engine.routes.draw do
  # Webhook endpoint (public, no auth)
  post "webhooks", to: "webhooks#create"

  # Account endpoints
  resource :account, only: [:show] do
    get :organizations
    get :repositories
  end

  # Creative integration endpoints
  resources :creatives, only: [] do
    resource :integration, module: :creatives, only: [:show, :update, :destroy]
  end
end
