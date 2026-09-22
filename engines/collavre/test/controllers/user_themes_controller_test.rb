require "test_helper"

class UserThemesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")
  end

  test "theme generation usage is visible to its human requester" do
    factory = ->(**options) {
      Collavre::LlmUsage::Recorder.new(context: options.fetch(:context), vendor: options[:vendor], model: options[:model]).finish
      client = Object.new
      def client.chat(*) = '{"--surface-bg":"#ffffff"}'
      client
    }
    Collavre::AiClient.stub(:new, factory) do
      post collavre.user_themes_url, params: { description: "Snow" }
    end
    assert_response :redirect
    usage = Collavre::LlmUsage.last
    assert_equal @user.id, usage.requester_id
    assert_nil usage.agent_id
    assert_nil usage.owner_id
    assert_includes Collavre::LlmUsage.visible_to(@user), usage
  end

  test "should get index" do
    get collavre.user_themes_url
    assert_response :success
  end

  test "uses the in-app Turbo confirmation for theme deletion" do
    @user.user_themes.create!(name: "Forest", variables: { "--surface-bg" => "#0f2d1f" })

    get collavre.user_themes_url

    assert_select "form[data-turbo-confirm=?]", I18n.t("collavre.themes.confirm_delete") do
      assert_select "input[name='_method'][value='delete']"
      assert_select "button.btn-danger", text: I18n.t("collavre.themes.delete")
    end
    assert_select "button[onclick*='confirm']", count: 0
  end
end
