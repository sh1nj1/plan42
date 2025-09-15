module ApplicationHelper
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

  def embed_youtube_iframe(html)
    return html if html.blank?
    html = html.to_s
    html.gsub(%r{<a[^>]+href=["']https?://(?:www\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([\w-]{11})[^"']*["'][^>]*>.*?</a>}i) do
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
    end.html_safe
  end
end
