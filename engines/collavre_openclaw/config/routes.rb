CollavreOpenclaw::Engine.routes.draw do
  # Callback endpoint for async responses from OpenClaw
  post "/callback/:user_id", to: "callbacks#create", as: :callback

  # Health check endpoint
  get "/health", to: "health#show"
end
