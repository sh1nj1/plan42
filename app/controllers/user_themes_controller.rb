class UserThemesController < ApplicationController
  def index
    @themes = Current.user.user_themes.order(created_at: :desc)
    @new_theme = UserTheme.new
  end

  def create
    description = params[:description]
    if description.blank?
      @error = t("themes.alerts.description_empty")
      @themes = Current.user.user_themes.order(created_at: :desc)
      @new_theme = UserTheme.new
      render :index
      return
    end

    variables = AutoThemeGenerator.new.generate(description)

    if variables.empty?
      @error = t("themes.alerts.generation_failed")
      @themes = Current.user.user_themes.order(created_at: :desc)
      @new_theme = UserTheme.new
      render :index
      return
    end

    variables["--creative-loading-emojis"] = emoji_css_value(description)

    # Generate a name from description or use first few words
    name = description.truncate(30)

    @theme = Current.user.user_themes.build(name: name, variables: variables)

    if @theme.save
      redirect_to user_themes_path, notice: t("themes.alerts.success")
    else
      redirect_to user_themes_path, alert: t("themes.alerts.save_failed")
    end
  end

  def destroy
    @theme = Current.user.user_themes.find(params[:id])
    @theme.destroy
    if Current.user.theme == @theme.id.to_s
      Current.user.update(theme: "light")
    end
    redirect_to user_themes_path, notice: t("themes.alerts.deleted")
  end

  def apply
    @theme = Current.user.user_themes.find(params[:id])
    if Current.user.update(theme: @theme.id.to_s)
      redirect_to user_themes_path, notice: t("themes.alerts.applied")
    else
      redirect_to user_themes_path, alert: t("themes.alerts.apply_failed", errors: Current.user.errors.full_messages.join(", "))
    end
  end

  private

  def emoji_css_value(description)
    requested = params[:emoji_set]
    if requested.present? && ThemeEmojiSelector::EMOJI_SETS.key?(requested.to_sym)
      return ThemeEmojiSelector::EMOJI_SETS[requested.to_sym].join(" ")
    end

    ThemeEmojiSelector.new(description).css_value
  end
end
