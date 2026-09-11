require_relative "../application_system_test_case"

# The empty-state disc is painted by a radial-gradient rather than by a
# border-radius background, to dodge an Android rasteriser defect that draws the
# last corner of a rounded-rect *fill* — bottom-left — as the straight chord of
# its arc. On a Galaxy S24 that turns the 56px disc into a shape with one folded
# corner. Rounded borders on the same page are unaffected, and the radius value
# makes no difference (1e5px, 9999px and 50% all resolve to the same used radius
# of 28px for this box), so the only fix available to us is to stop asking for a
# rounded rect at all.
#
# These guard the two halves of that: no rounded background clip may come back,
# and the disc must still actually be painted and actually be circular.
class CreativeEmptyStateIconDiscTest < ApplicationSystemTestCase
  ICON = ".creative-empty-state-icon".freeze

  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @parent_creative = Creative.create!(description: "Parent", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creative_path(@parent_creative)
    wait_for_network_idle(timeout: 10)
    assert_selector ICON, visible: true, wait: 5
  end

  # The regression guard. Re-adding any border-radius reinstates the rounded
  # background clip, and the folded corner with it.
  test "the disc carries no rounded-rect background clip" do
    radii = computed(ICON, %w[
      borderTopLeftRadius borderTopRightRadius
      borderBottomRightRadius borderBottomLeftRadius
    ])

    radii.each do |corner, value|
      assert_equal 0.0, value.to_f,
        "#{corner} is #{value}; a rounded background clip is what folds on Android"
    end
  end

  test "the disc is still painted, as a gradient" do
    background = computed(ICON, %w[backgroundImage backgroundColor])

    assert_match(/radial-gradient/, background["backgroundImage"],
      "the disc is no longer painted at all")
    assert_match(/closest-side/, background["backgroundImage"],
      "without closest-side the gradient sizes to the corner, not the edge")
    assert_match(/rgba\(0,\s*0,\s*0,\s*0\)|transparent/, background["backgroundColor"],
      "a flat background-color would paint a square behind the disc")
  end

  # `circle closest-side` inscribes the disc in the *shorter* side, so a
  # non-square box would render a circle with two flat sides rather than the
  # ellipse a percentage radius used to give. Keep the box square.
  test "the icon box is square, so closest-side yields a full circle" do
    box = page.evaluate_script(
      "(() => { const r = document.querySelector(#{ICON.to_json}).getBoundingClientRect();" \
      " return { w: r.width, h: r.height }; })()"
    )

    assert_operator box["w"], :>, 0
    assert_in_delta box["w"], box["h"], 0.5,
      "icon box is #{box['w']}x#{box['h']}; closest-side would flatten two sides"
  end

  private

  def computed(selector, properties)
    page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.querySelector(#{selector.to_json}));
        const out = {};
        #{properties.to_json}.forEach((p) => { out[p] = style[p]; });
        return out;
      })()
    JS
  end
end
