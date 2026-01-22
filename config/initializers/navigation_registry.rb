# frozen_string_literal: true

# Reset navigation registry before any registrations (runs first)
ActiveSupport::Reloader.to_prepare(prepend: true) do
  Navigation::Registry.instance.reset!
end

# Register core navigation items
# Engines can add their own items in their own initializers
Rails.application.config.to_prepare do
  # ============================================
  # Search Section
  # ============================================
  Navigation::Registry.instance.register(
    key: :search,
    label: "app.search_placeholder",
    section: :search,
    type: :partial,
    partial: "collavre/shared/navigation/search_form",
    priority: 10
  )

  # ============================================
  # Main Section - Mobile Only
  # ============================================
  Navigation::Registry.instance.register(
    key: :mobile_plans,
    label: "app.plans",
    type: :partial,
    partial: "collavre/shared/navigation/mobile_plans_button",
    priority: 100,
    requires_auth: true,
    desktop: false,
    mobile: true
  )

  # ============================================
  # Main Section - Desktop Navigation
  # ============================================
  Navigation::Registry.instance.register(
    key: :home,
    label: "app.home",
    type: :button,
    path: -> { main_app.root_path },
    priority: 110
  )

  Navigation::Registry.instance.register(
    key: :plans,
    label: "app.plans",
    type: :partial,
    partial: "collavre/shared/navigation/plans_button",
    priority: 120,
    requires_auth: true,
    mobile: false
  )

  Navigation::Registry.instance.register(
    key: :progress_filter,
    label: "",
    type: :component,
    component: Collavre::ProgressFilterComponent,
    component_args: {
      current_state: -> {
        if params[:min_progress] == "1" && params[:max_progress] == "1"
          :complete
        elsif params[:min_progress] == "0" && params[:max_progress] == "0.99"
          :incomplete
        else
          :all
        end
      },
      states: [
        { name: -> { I18n.t("app.filter_complete") }, value: :complete },
        { name: -> { I18n.t("app.filter_incomplete") }, value: :incomplete },
        { name: -> { I18n.t("app.filter_all") }, value: :all }
      ]
    },
    priority: 130,
    requires_auth: true
  )

  Navigation::Registry.instance.register(
    key: :comment_filter,
    label: "",
    type: :component,
    component: Collavre::ProgressFilterComponent,
    component_args: {
      current_state: -> { params[:comment] == "true" ? :comment : nil },
      states: [
        { name: -> { I18n.t("app.filter_comments") }, value: :comment }
      ]
    },
    priority: 140,
    requires_auth: true
  )

  Navigation::Registry.instance.register(
    key: :inbox,
    label: "app.inbox",
    type: :partial,
    partial: "collavre/shared/navigation/inbox_button",
    priority: 150,
    requires_user: true,
    mobile: false
  )

  Navigation::Registry.instance.register(
    key: :mobile_inbox,
    label: "app.inbox",
    type: :partial,
    partial: "collavre/shared/navigation/mobile_inbox_button",
    priority: 155,
    requires_user: true,
    desktop: false,
    mobile: true
  )

  Navigation::Registry.instance.register(
    key: :sign_in,
    label: "app.sign_in",
    type: :button,
    path: -> { Collavre::Engine.routes.url_helpers.new_session_path },
    priority: 160,
    visible: -> { !authenticated? }
  )

  Navigation::Registry.instance.register(
    key: :help,
    label: "?",
    type: :partial,
    partial: "collavre/shared/navigation/help_button",
    priority: 170
  )

  # ============================================
  # User Section
  # ============================================
  Navigation::Registry.instance.register(
    key: :user_menu,
    label: "",
    section: :user,
    type: :raw,
    button_content: -> { render(AvatarComponent.new(user: Current.user, size: 32, classes: "nav-avatar avatar")) },
    menu_id: "user-menu",
    align: :right,
    priority: 100,
    requires_user: true,
    children: [
      {
        key: :profile,
        label: "collavre.users.profile",
        type: :button,
        path: -> { Collavre::Engine.routes.url_helpers.user_path(Current.user) },
        html_class: "popup-menu-item",
        priority: 100
      },
      {
        key: :sign_out,
        label: "app.sign_out",
        type: :button,
        path: -> { Collavre::Engine.routes.url_helpers.session_path },
        method: :delete,
        priority: 900
      }
    ]
  )
end
