CollavreSlack::Engine.routes.draw do
  get "/auth/slack", to: "slack_auth#start"
  get "/auth/slack/callback", to: "slack_auth#callback"

  resources :creatives, only: [] do
    resources :slack_integrations, module: :creatives, only: [ :index, :create, :destroy ] do
      collection do
        get :badge
      end
    end
    resources :slack_messages, only: [ :create ]
  end

  post "/slack/events", to: "slack_events#create"
end
