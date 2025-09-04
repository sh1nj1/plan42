module ApplicationHelper
  include CreativesHelper
  def user_avatar_url(user, size: 32)
    if user.avatar.attached?
      url_for(user.avatar.variant(resize_to_fill: [ size, size ]))
    elsif user.avatar_url.present?
      user.avatar_url
    else
      asset_path("default_avatar.svg")
    end
  end

  def svg_tag(name, options = {})
    # Resolve path (looks in app/assets/images by default)
    file_path = Rails.root.join("app", "assets", "images", "#{name.end_with?('.svg') ? name : "#{name}.svg"}")

    if File.exist?(file_path)
      # Read the SVG
      svg = File.read(file_path)

      # Add/merge class and set width/height if provided in options
      if options[:class].present? || options[:width].present? || options[:height].present?
        svg.sub!(/<svg\b([^>]*)>/) do |match|
          attrs = Regexp.last_match(1)

          [ :class, :width, :height ].each do |attr|
            next unless options[attr].present?

            if attr == :class
              if attrs =~ /\bclass=\"([^\"]*)\"/
                attrs = attrs.sub(/\bclass=\"([^\"]*)\"/, "class=\"#{$1} #{options[:class]}\"")
              else
                attrs = "#{attrs} class=\"#{options[:class]}\""
              end
            else
              if attrs =~ /\b#{attr}=\"[^\"]*\"/
                attrs = attrs.sub(/\b#{attr}=\"[^\"]*\"/, "#{attr}=\"#{options[attr]}\"")
              else
                attrs = "#{attrs} #{attr}=\"#{options[attr]}\""
              end
            end
          end

          "<svg#{attrs}>"
        end
      end

      raw(svg) # mark as HTML safe
    else
      "<div>(missing svg: #{name})</div>"
    end
  end

  def linkify_urls(text)
    ERB::Util.html_escape(text.to_s).gsub(%r{https?://[^\s]+}) do |url|
      link_to(url, url, target: "_blank", rel: "noopener")
    end.html_safe
  end

  class SafeMarkdownRenderer < Redcarpet::Render::HTML
    def initialize
      super(filter_html: true, hard_wrap: true, link_attributes: { target: "_blank", rel: "noopener" })
    end
  end

  def markdown_renderer
    @markdown_renderer ||= Redcarpet::Markdown.new(SafeMarkdownRenderer.new, autolink: true)
  end

  def render_markdown(text)
    markdown_renderer.render(text.to_s).html_safe
  end
end
