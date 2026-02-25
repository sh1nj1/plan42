CollavreCompletionApi::Engine.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :models, only: [ :index ]
      namespace :chat do
        resources :completions, only: [ :create ]
      end
    end
  end
end
