class UserThemesController < ApplicationController
  def index
    @themes = Current.user.user_themes.order(created_at: :desc)
    @new_theme = UserTheme.new
  end

  def create
    description = params[:description]
    if description.blank?
      @error = "Theme description cannot be empty."
      @themes = Current.user.user_themes.order(created_at: :desc)
      @new_theme = UserTheme.new
      render :index
      return
    end

    variables = AutoThemeGenerator.new.generate(description)

    if variables.empty?
      @error = "Failed to generate theme. AI might be unavailable or returned invalid data."
      @themes = Current.user.user_themes.order(created_at: :desc)
      @new_theme = UserTheme.new
      render :index
      return
    end

    # Generate a name from description or use first few words
    name = description.truncate(30)

    @theme = Current.user.user_themes.build(name: name, variables: variables)

    if @theme.save
      redirect_to user_themes_path, notice: "Theme generated successfully!"
    else
      redirect_to user_themes_path, alert: "Failed to save theme."
    end
  end

  def destroy
    @theme = Current.user.user_themes.find(params[:id])
    @theme.destroy
    if Current.user.theme == @theme.id.to_s
      Current.user.update(theme: "light")
    end
    redirect_to user_themes_path, notice: "Theme deleted."
  end

  def apply
    @theme = Current.user.user_themes.find(params[:id])
    if Current.user.update(theme: @theme.id.to_s)
      redirect_to user_themes_path, notice: "Theme applied!"
    else
      redirect_to user_themes_path, alert: "Failed to apply theme: #{Current.user.errors.full_messages.join(', ')}"
    end
  end
end
