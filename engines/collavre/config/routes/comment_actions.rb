# frozen_string_literal: true

resource :resend, only: :create, module: :comments
resources :reactions, only: [ :create ], module: :comments
resource :activity_log, only: [ :show ], module: :comments
resources :versions, only: [ :index, :destroy ], module: :comments do
  member do
    post :select
  end
end
