# Public feature guides — the long-form counterpart to the empty-chat feature
# cards. Keys come from Collavre::FeatureCardRegistry, which rejects a key this
# constraint could not route, so the two cannot drift apart.
get "features", to: "features#index", as: :features
get "features/:key", to: "features#show", as: :feature, constraints: { key: Collavre::FeatureCard::GUIDE_KEY_FORMAT }

# Public, server-rendered pages for publicly shared creatives
get "p/:public_id(/:slug)", to: "public_creatives#show", as: :public_creative,
    constraints: { public_id: Collavre::Creative::Publishable::PUBLIC_ID_FORMAT }, format: false
