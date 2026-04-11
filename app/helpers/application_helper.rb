module ApplicationHelper
  include Collavre::ApplicationHelper
  include Collavre::NavigationHelper
  include Collavre::CreativesHelper
  include Collavre::CommentsHelper
  def user_avatar_url(user, size: 32)
    if user.avatar.attached?
      main_app.url_for(user.avatar.variant(resize_to_fill: [ size, size ]))
    elsif user.avatar_url.present?
      user.avatar_url
    else
      asset_path("default_avatar.svg")
    end
  end

  def svg_tag(name, options = {})
    # Reject path traversal attempts
    return content_tag(:div, "(invalid svg name: #{ERB::Util.html_escape(name)})") if name.include?("..") || name.include?("/")

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
            escaped_value = ERB::Util.html_escape(options[attr])

            if attr == :class
              if attrs =~ /\bclass=\"([^\"]*)\"/
                attrs = attrs.sub(/\bclass=\"([^\"]*)\"/, "class=\"#{$1} #{escaped_value}\"")
              else
                attrs = "#{attrs} class=\"#{escaped_value}\""
              end
            else
              if attrs =~ /\b#{attr}=\"[^\"]*\"/
                attrs = attrs.sub(/\b#{attr}=\"[^\"]*\"/, "#{attr}=\"#{escaped_value}\"")
              else
                attrs = "#{attrs} #{attr}=\"#{escaped_value}\""
              end
            end
          end

          "<svg#{attrs}>"
        end
      end

      raw(svg) # mark as HTML safe
    else
      content_tag(:div, "(missing svg: #{ERB::Util.html_escape(name)})")
    end
  end

  EMBED_ALLOWED_TAGS = %w[iframe a p div span br strong em b i u ul ol li h1 h2 h3 h4 h5 h6 blockquote code pre img hr table thead tbody tr th td figure figcaption action-text-attachment].freeze
  EMBED_ALLOWED_ATTRS = %w[src title frameborder allow allowfullscreen style href class alt width height target rel sgid content-type filename colspan rowspan].freeze

  def embed_youtube_iframe(html)
    return html if html.blank?
    html = html.to_s
    result = html.gsub(%r{<a[^>]+href=["']https?://(?:www\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([\w-]{11})[^"']*["'][^>]*>.*?</a>}i) do
      video_id = Regexp.last_match(1)
      tag.iframe(
        "",
        src: "https://www.youtube.com/embed/#{video_id}",
        title: "YouTube video player",
        frameborder: 0,
        allow: "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share",
        allowfullscreen: true,
        style: "width: min(60vw, calc(var(--max-width) - 60px)); aspect-ratio: 16 / 9;"
      )
    end
    sanitize(result, tags: EMBED_ALLOWED_TAGS, attributes: EMBED_ALLOWED_ATTRS)
  end

  def creative_title_for_display(creative, length: 12)
    return "" unless creative

    description_body = creative.effective_origin.description
    title = description_body ? strip_tags(description_body) : ""
    title.strip.truncate(length, omission: "...")
  end

  def render_contact_creatives(creatives)
    return safe_join([]) if creatives.blank?

    safe_join(creatives.map do |creative|
      link_to(creative_title_for_display(creative), collavre.creative_path(creative), class: "creative-chip")
    end)
  end
end
