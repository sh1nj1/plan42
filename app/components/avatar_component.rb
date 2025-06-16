class AvatarComponent < ViewComponent::Base
  def initialize(user:, size: 32, classes: "")
    @user = user
    @size = size
    @classes = classes
  end

  attr_reader :size, :classes

  def avatar_url
    if @user
      helpers.user_avatar_url(@user, size: @size)
    else
      helpers.asset_path("default_avatar.svg")
    end
  end

  def email
    @user&.email || I18n.t("comments.anonymous")
  end
end
