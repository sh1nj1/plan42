Mis2::Engine.routes.draw do
  root to: "home#index"
  resources :activity_logs, only: [ :index ]

  namespace :h2 do
    resources :assignments, only: [ :index, :edit, :update ] do
      collection do
        post :validate
      end
    end
  end
end
