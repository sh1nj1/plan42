# frozen_string_literal: true

module Collavre
  module NavigationHelper
    # Get visible navigation items for a section
    def navigation_items_for(section, desktop: true)
      Navigation::Registry.instance
        .items_for_section(section)
        .select { |item| navigation_item_visible?(item, desktop: desktop) }
    end

    # Check if a navigation item should be visible
    def navigation_item_visible?(item, desktop: true)
      return false if desktop && !item[:desktop]
      return false if !desktop && !item[:mobile]
      return false if item[:requires_auth] && !authenticated?
      return false if item[:requires_user] && Current.user.nil?

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
      when :popup
        render_nav_dropdown(item, mobile: mobile)
      else
        raise ArgumentError, "Unknown navigation item type: #{item[:type]}"
      end
    end

    def render_navigation_item_with_children(item, mobile: false)
      return unless navigation_item_visible?(item, desktop: !mobile)

      if item[:children].present?
        render_nav_dropdown(item, mobile: mobile)
      else
        render_navigation_item(item, mobile: mobile)
      end
    end

    def resolve_nav_value(value)
      value.is_a?(Proc) ? instance_exec(&value) : value
    end

    # True when a URL leaves this application — an absolute URL whose origin is
    # not ours. The whole origin has to match, not just the host: a different
    # scheme or port on the same host is a different service (the desktop shell
    # runs on 127.0.0.1, where a docs server on another port shares our host but
    # none of our pages), and navigating in place would replace the app with
    # something that cannot offer a way back. A scheme-relative URL ("//host/x")
    # inherits only our scheme: the browser resolves the omitted port to that
    # scheme's default, not to the port we happen to be served on, so that is
    # what we compare. Relative paths and same-origin absolute URLs are ours and
    # stay in the current window.
    #
    # Wherever Ruby's parser and a browser disagree, the value is treated as
    # off-site, decided by whether it is written with an authority. Ruby rejects
    # an internationalized domain that a browser punycodes and navigates to, and
    # it finds no host in "///docs.example.com/help" where a browser skips the
    # extra slashes and lands on docs.example.com. "Ours" is the wrong guess in
    # both, and it is the guess that strands the reader. Something written
    # without an authority is a relative path, however odd, and stays internal.
    # The cost is a same-origin URL written with extra slashes opening a tab.
    AUTHORITY_PREFIX = %r{\A(?:[a-z][a-z0-9+.\-]*:)?//}i

    def external_link?(url)
      value = url.to_s
      written_with_authority = value.match?(AUTHORITY_PREFIX)
      uri = URI.parse(value)
      return written_with_authority if uri.host.blank?

      scheme = uri.scheme.presence&.downcase || request.scheme
      port = uri.port || URI.scheme_list[scheme.upcase]&.default_port

      [ scheme, uri.host.downcase, port ] !=
        [ request.scheme, request.host.downcase, request.port ]
    # URI::InvalidComponentError is a sibling of URI::InvalidURIError, not a
    # subclass — "mailto://x@y.com" raises it, and letting it escape would take
    # down every page carrying the navigation.
    rescue URI::Error
      written_with_authority
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
      return safe_join([]) if content.nil?
      content.respond_to?(:html_safe?) && content.html_safe? ? content : ERB::Util.html_escape(content)
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
        safe_join(children.map { |child| render_dropdown_child(child, mobile: mobile) })
      end
    end

    def render_dropdown_child(item, mobile: false)
      content = render_navigation_item(item, mobile: mobile)
      return if content.blank?
      content_tag(:div, content, class: "popup-menu-item")
    end

    def resolve_nav_label(label)
      return "" if label.blank?
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
end
