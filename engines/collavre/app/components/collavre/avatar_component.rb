module Collavre
class AvatarComponent < ViewComponent::Base
  # Enable fragment caching for avatar components
  # Cache key includes user version (for display_name changes), avatar blob key, and size
  def self.cache_key_for(user, size)
    if user
      avatar_key = user.avatar.attached? ? user.avatar.blob&.key : user.avatar_url.to_s
      "avatar/#{user.cache_key_with_version}/#{avatar_key}/#{size}"
    else
      "avatar/anonymous/#{size}"
    end
  end

  def initialize(user:, size: 32, classes: "", data: {})
    @user = user
    @size = size
    @classes = classes
    @data = data
  end

  attr_reader :size, :classes, :data

  # Cache key for this component instance
  def cache_key
    self.class.cache_key_for(@user, @size)
  end

  def avatar_url
    # Cache avatar URL computation
    @avatar_url ||= compute_avatar_url
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

  private

  def compute_avatar_url
    if @user
      helpers.user_avatar_url(@user, size: @size)
    else
      helpers.asset_path("default_avatar.svg")
    end
  end
end
end
