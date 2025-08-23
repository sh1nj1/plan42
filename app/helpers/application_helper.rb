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

      # Add class or other options if passed
      if options[:class].present?
        # inject class into the <svg ...> tag
        svg.sub!("<svg", "<svg class=\"#{options[:class]}\"")
      end

      raw(svg) # mark as HTML safe
    else
      "<div>(missing svg: #{name})</div>"
    end
  end
end
