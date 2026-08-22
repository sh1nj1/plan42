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
    # Where Ruby's parser hands back no host at all, the spelling decides —
    # see #leaves_origin_by_spelling?.
    def external_link?(url)
      value = browser_normalized(url.to_s)
      uri = URI.parse(value)
      return leaves_origin_by_spelling?(value) if uri.host.blank?

      scheme = uri.scheme.presence&.downcase || request.scheme
      port = uri.port || URI.scheme_list[scheme.upcase]&.default_port

      [ scheme, uri.host.downcase, port ] !=
        [ request.scheme, request.host.downcase, request.port ]
    # URI::InvalidComponentError is a sibling of URI::InvalidURIError, not a
    # subclass — "mailto://x@y.com" raises it, and letting it escape would take
    # down every page carrying the navigation.
    rescue URI::Error
      leaves_origin_by_spelling?(value)
    end

    # True when a URL runs code in whatever document it is clicked from instead
    # of naming a page to go to. Such a value is never a help page, and no
    # window target makes it safe: the one guard the HTML Standard places on a
    # "javascript:" navigation is that the initiator is same origin-domain with
    # the target, and a "_blank" auxiliary context starts on an about:blank that
    # inherits the opener's origin — so the script runs there too, with our
    # cookies. It has to be dropped rather than re-targeted.
    def executable_url?(url)
      browser_normalized(url.to_s).match?(EXECUTABLE_SCHEME)
    end

    private

    # What a browser throws away before it parses anything: every tab and
    # newline wherever they sit, then leading and trailing C0 controls and
    # spaces. A setting saved with stray whitespace would otherwise be measured
    # against a string no browser ever sees — " https://docs.example.com/help"
    # is off-site to them and unparseable to us.
    IGNORED_IN_URL = /[\t\n\r]/
    SURROUNDING_CONTROLS = /\A[\x00-\x20]+|[\x00-\x20]+\z/

    def browser_normalized(value)
      value.gsub(IGNORED_IN_URL, "").gsub(SURROUNDING_CONTROLS, "")
    end

    # Ruby's parser and a browser disagree about several spellings, and Ruby
    # losing the host is where that shows: it rejects an internationalized
    # domain the browser punycodes, and finds nothing in "///docs.example.com"
    # or "https:/docs.example.com" where the browser skips the slashes and takes
    # the next segment as the host. Reading those as ours is the guess that
    # strands the reader, so the decision falls back to how the value is
    # written.
    #
    # Two of any slash start an authority and leave — for a special scheme the
    # browser reads "\" as "/", so "\\docs.example.com" is an authority while a
    # single "\" is just a path separator. So does an http(s) scheme that is not
    # the one we are served over; with a matching scheme the browser reads the
    # rest as a path on our origin instead, which is why the scheme is compared
    # rather than merely detected. So does a scheme that replaces the document
    # with one of its own — see DOCUMENT_SCHEME. Everything else — a relative
    # path, "mailto:", "tel:", an OS handler — is ours: those hand the URL to
    # something else and leave the page where it is.
    AUTHORITY_PREFIX = %r{\A(?:[a-z][a-z0-9+.\-]*:)?[/\\]{2}}i
    SPECIAL_SCHEME_PREFIX = /\A(https?):/i

    # Schemes that build a document instead of handing the URL off. None of them
    # can carry our navigation, and "about:blank" is the plain case: it replaces
    # the page with an empty one that has nothing to click. A browser refuses the
    # top-level click for several of the others ("data:", "file:" from an http
    # page), which costs nothing here — a new tab and a refused navigation are
    # equally harmless, so the list is drawn around what the scheme *would*
    # render rather than around which shell happens to block it.
    DOCUMENT_SCHEME = /\A(?:about|blob|data|file|filesystem|view-source):/i

    # Schemes that execute rather than point anywhere — see #executable_url?.
    # Kept apart from DOCUMENT_SCHEME because the question they answer is a
    # different one: not "which window does this open in" but "may this be an
    # href at all". The answer is no, so the value never reaches external_link?.
    EXECUTABLE_SCHEME = /\A(?:javascript|vbscript):/i

    def leaves_origin_by_spelling?(value)
      return true if value.match?(AUTHORITY_PREFIX)
      return true if value.match?(DOCUMENT_SCHEME)

      scheme = value[SPECIAL_SCHEME_PREFIX, 1]
      scheme.present? && scheme.downcase != request.scheme
    end

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
