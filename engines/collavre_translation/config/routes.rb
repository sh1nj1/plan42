CollavreTranslation::Engine.routes.draw do
  resources :creatives, only: [] do
    resource :translation, only: [ :show, :create ], controller: :creative_translations
  end
  resources :comments, only: [] do
    resource :translation, only: [ :show, :create ]
  end
end
