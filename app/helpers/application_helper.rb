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
end
