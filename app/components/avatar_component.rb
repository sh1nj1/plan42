class AvatarComponent < ViewComponent::Base
  def initialize(user:, size: 32, classes: "", data: {})
    @user = user
    @size = size
    @classes = classes
    @data = data
  end

  attr_reader :size, :classes, :data

  def avatar_url
    if @user
      helpers.user_avatar_url(@user, size: @size)
    else
      helpers.asset_path("default_avatar.svg")
    end
  end

  def default_avatar?
    @user && !@user.avatar.attached? && @user.avatar_url.blank?
  end

  def initial
    @user.display_name[0].upcase
  end

  def email
    if @user
      @user.display_name
    else
      I18n.t("comments.anonymous")
    end
  end
end
