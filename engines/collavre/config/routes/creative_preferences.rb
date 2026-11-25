post "/creative_expanded_states/fence", to: "user_creative_preferences#issue_expansion_save_fence"
post "/creative_expanded_states/toggle", to: "user_creative_preferences#toggle"
match "/creatives/:creative_id/user_creative_preferences/update_last_topic", to: "user_creative_preferences#update_last_topic", via: [ :post, :patch ], as: :update_last_topic
