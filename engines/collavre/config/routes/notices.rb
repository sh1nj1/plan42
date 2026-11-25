# Inline hint dismissals (User#dismissed_notices)
post "/notices/:key/dismiss", to: "notices#dismiss", as: :dismiss_notice
delete "/notices", to: "notices#restore_all", as: :restore_notices

# Notice bar: announcements, feature guides and onboarding missions (UserNotice)
resources :user_notices, only: [ :index ], param: :key, constraints: { key: /[a-z0-9_]+/ } do
  member do
    post :dismiss
    post :snooze
    post :complete
    post :restore
  end
end

# Explicitly restart only the current user's onboarding missions.
resource :onboarding_replay, only: :create
