Rails.application.config.after_initialize do
  configure_navigation = -> do
    # Remove default items
    [ :home, :plans, :progress_filter, :comment_filter, :help, :search, :mobile_plans ].each do |key|
      Navigation::Registry.instance.unregister(key)
    end

    # Register mis2 root
    Navigation::Registry.instance.register(
      key: :mis2,
      label: "MIS2",
      type: :button,
      path: -> { mis2.root_path },
      priority: 10,
      requires_auth: true
    )

    # Register lab (creatives)
    Navigation::Registry.instance.register(
      key: :lab,
      label: "LAB",
      type: :button,
      path: -> { "/creatives" },
      priority: 110,
      requires_auth: true
    )
  end

  # Run immediately (for first boot, as to_prepare callbacks have likely already run)
  configure_navigation.call

  # Register for future reloads (reloads will trigger this after the Host's reset!)
  ActiveSupport::Reloader.to_prepare(&configure_navigation)
end
