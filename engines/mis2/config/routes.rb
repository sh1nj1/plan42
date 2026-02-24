Mis2::Engine.routes.draw do
  root to: "home#index"
  resources :activity_logs, only: [ :index, :show ] do
    member do
      patch :undo
    end
  end

  namespace :h3 do
    resources :organizations, only: [ :index ] do
      member do
        patch :approve
      end
    end
  end

  namespace :h2 do
    resources :assignments, only: [ :index, :edit, :update, :destroy ] do
      collection do
        post :validate
      end
    end

    resources :organizations, only: [] do
      collection do
        get :search
      end
    end

    resources :users, only: [] do
      member do
        patch :update_organization
      end
    end
  end
end
