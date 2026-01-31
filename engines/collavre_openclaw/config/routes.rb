CollavreOpenclaw::Engine.routes.draw do
  # Account management (for AI agent users)
  resources :accounts, only: [ :new, :create, :edit, :update, :destroy ]

  # Callback endpoint for async responses from OpenClaw
  post "/callback/:account_id", to: "callbacks#create", as: :callback

  # Health check endpoint
  get "/health", to: "health#show"
end
