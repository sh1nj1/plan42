# frozen_string_literal: true

module NavigationHelper
  # Get visible navigation items for a section
  def navigation_items_for(section, desktop: true)
    Navigation::Registry.instance
      .items_for_section(section)
      .select { |item| navigation_item_visible?(item, desktop: desktop) }
  end

  # Check if a navigation item should be visible
  def navigation_item_visible?(item, desktop: true)
    # Check desktop/mobile visibility
    return false if desktop && !item[:desktop]
    return false if !desktop && !item[:mobile]

    # Check authentication requirements
    return false if item[:requires_auth] && !authenticated?
    return false if item[:requires_user] && Current.user.nil?

    # Check custom visibility proc
    if item[:visible].is_a?(Proc)
      return false unless resolve_nav_value(item[:visible])
    end

    true
  end

  # Render a single navigation item
  def render_navigation_item(item, mobile: false)
    return unless navigation_item_visible?(item, desktop: !mobile)

    case item[:type]
    when :button
      render_nav_button(item)
    when :link
      render_nav_link(item)
    when :component
      render_nav_component(item)
    when :partial
      render_nav_partial(item)
    when :divider
      render_nav_divider(item)
    when :raw
      render_nav_raw(item)
    else
      raise ArgumentError, "Unknown navigation item type: #{item[:type]}"
    end
  end

  # Render a mobile navigation item with wrapper
  def render_mobile_navigation_item(item)
    content = render_navigation_item(item, mobile: true)
    return if content.blank?

    content_tag(:div, content)
  end

  # Render a navigation item with children (for dropdowns)
  def render_navigation_item_with_children(item, mobile: false)
    return unless navigation_item_visible?(item, desktop: !mobile)

    if item[:children].present?
      render_nav_dropdown(item, mobile: mobile)
    else
      render_navigation_item(item, mobile: mobile)
    end
  end

  # Evaluate a proc in the current view context, or return value as-is
  def resolve_nav_value(value)
    value.is_a?(Proc) ? instance_exec(&value) : value
  end

  private

  def render_nav_button(item)
    path = resolve_nav_value(item[:path])
    label = resolve_nav_label(item[:label])
    method = item[:method] || :get
    html_options = build_html_options(item)

    button_to(label, path, method: method, **html_options)
  end

  def render_nav_link(item)
    path = resolve_nav_value(item[:path])
    label = resolve_nav_label(item[:label])
    html_options = build_html_options(item)

    link_to(label, path, **html_options)
  end

  def render_nav_component(item)
    component_class = item[:component]
    args = resolve_component_args(item[:component_args] || {})

    render(component_class.new(**args))
  end

  def render_nav_partial(item)
    partial = item[:partial]
    locals = resolve_component_args(item[:locals] || {})

    render(partial: partial, locals: locals)
  end

  def render_nav_divider(item)
    html_options = build_html_options(item)
    content_tag(:hr, nil, **html_options)
  end

  def render_nav_raw(item)
    content = resolve_nav_value(item[:content])
    content.respond_to?(:html_safe) ? content.html_safe : content
  end

  def render_nav_dropdown(item, mobile: false)
    button_content = resolve_nav_value(item[:button_content]) || resolve_nav_label(item[:label])
    menu_id = item[:menu_id] || "#{item[:key]}-menu"
    align = item[:align] || :right

    children = (item[:children] || []).select { |c| navigation_item_visible?(c, desktop: !mobile) }

    render(PopupMenuComponent.new(
             button_content: button_content,
             menu_id: menu_id,
             align: align
           )) do
      safe_join(children.map { |child| render_mobile_navigation_item(child) })
    end
  end

  def resolve_nav_label(label)
    return "" if label.blank?

    # Try I18n lookup if label looks like a translation key
    if label.is_a?(String) && label.include?(".")
      I18n.t(label, default: label)
    else
      label.to_s
    end
  end

  def resolve_component_args(args)
    deep_resolve_procs(args)
  end

  def deep_resolve_procs(value)
    case value
    when Proc
      instance_exec(&value)
    when Hash
      value.transform_values { |v| deep_resolve_procs(v) }
    when Array
      value.map { |v| deep_resolve_procs(v) }
    else
      value
    end
  end

  def build_html_options(item)
    options = {}
    options[:class] = item[:html_class] if item[:html_class]
    options[:id] = item[:html_id] if item[:html_id]
    options[:data] = item[:data] if item[:data]
    options
  end
end
