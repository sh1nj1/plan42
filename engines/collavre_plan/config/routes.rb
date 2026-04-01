CollavrePlan::Engine.routes.draw do
  resources :plans, only: [ :create, :destroy, :index, :update ]
  resource :creative_plan, only: [ :create, :destroy ], controller: "creative_plans"
end
