resources :llm_usages, only: :index, path: "settings/token-usage"
resources :agent_gateways, path: "settings/agent-gateways", except: :show do
  post :check, on: :member
end
