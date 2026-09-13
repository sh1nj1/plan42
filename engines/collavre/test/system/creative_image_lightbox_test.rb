require_relative "../application_system_test_case"

class CreativeImageLightboxTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "image-viewer@example.com", password: SystemHelpers::PASSWORD,
                         name: "Image Viewer", email_verified_at: Time.current, notifications_enabled: false)
    @creative = Creative.create!(user: @user, description: "Image gallery")
    file = Rails.root.join("engines/collavre/test/fixtures/files/small.png")
    %w[first.png second.png].each do |filename|
      File.open(file) do |io|
        blob = ActiveStorage::Blob.create_and_upload!(io: io, filename: filename, content_type: "image/png")
        @creative.files.attach(blob)
      end
    end
    urls = @creative.files.map { |image| Rails.application.routes.url_helpers.rails_blob_path(image, only_path: true) }
    @creative.update!(description: "<p>Image gallery</p><img src='#{urls.first}' alt='First' width='80' height='80'><a href='/creatives'><img src='#{urls.last}' alt='Second' width='80' height='80'></a>")
    resize_window_to
    sign_in_via_ui(@user)
  end

  test "the gallery navigates images across creative rows in list order" do
    sibling = Creative.create!(user: @user, description: "Another gallery")
    sibling.files.attach(@creative.files.first.blob)
    url = Rails.application.routes.url_helpers.rails_blob_path(sibling.files.first, only_path: true)
    sibling.update!(description: "<img src='#{url}' alt='Sibling' width='80' height='80'>")

    visit collavre.creatives_path
    assert_selector "#creative-#{sibling.id} img[alt='Sibling']"
    images = all(".creative-content img[src]")
    expected_alts = images.map { |image| image[:alt] }
    assert_equal 3, expected_alts.size
    images.last.click
    assert_selector ".image-lightbox-counter", text: "3 / 3"
    find(".image-lightbox-next").click
    assert_selector ".image-lightbox-image[alt='#{expected_alts.first}']"
    find(".image-lightbox-prev").click
    assert_selector ".image-lightbox-image[alt='#{expected_alts.last}']"
    page.driver.browser.action.send_keys(:arrow_left).perform
    assert_selector ".image-lightbox-image[alt='#{expected_alts[1]}']"
    assert_current_path collavre.creatives_path
  end

  test "collapsed child images are excluded and regain keyboard access when expanded" do
    child = Creative.create!(user: @user, parent: @creative, description: "Child gallery")
    child.update!(description: @creative.description.sub("First", "Child"))
    visit collavre.creatives_path
    parent_row = "creative-tree-row[dom-id='creative-#{@creative.id}']"
    child_image = "#creative-#{child.id} img[alt='Child']"

    find("#{parent_row} .creative-toggle-btn").click
    assert_selector child_image
    find("#{parent_row} .creative-toggle-btn").click
    assert_no_selector child_image
    assert_selector child_image, visible: :hidden
    find("#creative-#{@creative.id} img[alt='First']").click
    assert_selector ".image-lightbox-counter", text: "1 / 2"
    find(".image-lightbox-next").click
    assert_selector ".image-lightbox-image[alt='Second']"
    find(".image-lightbox-next").click
    assert_selector ".image-lightbox-image[alt='First']"
    find(".image-lightbox-close").click

    find("#{parent_row} .creative-toggle-btn").click
    image = find("#{child_image}[role='button'][tabindex='0']")
    page.execute_script("arguments[0].focus()", image)
    page.driver.browser.action.send_keys(:enter).perform
    assert_selector ".image-lightbox-counter", text: "3 / 4"
    assert_selector ".image-lightbox-image[alt='Child']"
  end

  test "images in a row being edited are excluded until editing closes" do
    sibling = Creative.create!(user: @user, description: @creative.description)
    visit collavre.creatives_path
    row = "creative-tree-row[dom-id='creative-#{sibling.id}']"
    find("#{row} .creative-row").hover
    find("#{row} .edit-inline-btn").click
    assert_selector "#inline-edit-form-element"
    assert_selector "#creative-#{sibling.id} img[alt='First']", visible: :hidden

    find("#creative-#{@creative.id} img[alt='First']").click
    assert_selector ".image-lightbox-counter", text: "1 / 2"
    find(".image-lightbox-close").click
    find("#inline-close").click
    assert_no_selector "#inline-edit-form-element"
    find("#creative-#{@creative.id} img[alt='First']").click
    assert_selector ".image-lightbox-counter", text: %r{[13] / 4}
  end

  test "selection mode selects image rows and restores the viewer when cancelled" do
    visit collavre.creatives_path
    assert_selector "#creative-#{@creative.id} img[alt='First']"
    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click

    find("#creative-#{@creative.id} img[alt='First']").click
    assert_selector "#creative-#{@creative.id} .select-creative-checkbox:checked"
    assert_no_selector ".image-lightbox-dialog"

    first = find("#creative-#{@creative.id} img[alt='First']")
    page.execute_script("arguments[0].focus()", first)
    [ :enter, :space ].each do |key|
      page.driver.browser.action.send_keys(key).perform
      assert_no_selector "#inline-edit-form"
      assert_no_selector ".image-lightbox-dialog"
      assert_selector "#creative-#{@creative.id} .select-creative-checkbox:checked"
    end

    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click
    assert_no_selector "#creative-#{@creative.id} .select-creative-checkbox:checked", visible: :all
    find("#creative-#{@creative.id} img[alt='First']").click
    assert_selector ".image-lightbox-dialog[open] .image-lightbox-counter", text: "1 / 2"
  end

  test "keyboard users can focus images and open the viewer from images and links" do
    [ collavre.creatives_path, collavre.creatives_path(id: @creative.id) ].each do |path|
      visit path
      if path.include?("?")
        # The title page opens chat automatically; finish that transition first.
        assert_docked_comments_loaded
        # Composer focus is scheduled in the animation frame after list loading.
        assert_selector "#comments-popup textarea:focus"
      end
      scope = path.include?("?") ? ".creative-title-content" : "#creative-#{@creative.id}"
      first = find("#{scope} img[alt='First'][role='button']")
      link = find("#{scope} a:has(img[alt='Second'])")
      page.execute_script("arguments[0].focus()", link)
      assert_equal link, page.evaluate_script("document.activeElement")
      page.driver.browser.action.key_down(:shift).send_keys(:tab).key_up(:shift).perform
      assert_equal first, page.evaluate_script("document.activeElement")

      page.driver.browser.action.send_keys(:space).perform
      assert_selector ".image-lightbox-dialog[open] .image-lightbox-counter", text: "1 / 2"
      page.driver.browser.action.send_keys(:escape).perform
      assert_no_selector ".image-lightbox-dialog"
      assert_equal first, page.evaluate_script("document.activeElement")

      page.driver.browser.action.send_keys(:enter).perform
      assert_selector ".image-lightbox-dialog[open] .image-lightbox-counter", text: "1 / 2"
      page.driver.browser.action.send_keys(:escape).perform
      assert_no_selector ".image-lightbox-dialog"
      page.driver.browser.action.send_keys(:tab).perform
      assert_equal link, page.evaluate_script("document.activeElement")
      page.driver.browser.action.send_keys(:enter).perform
      assert_selector ".image-lightbox-dialog[open] .image-lightbox-counter", text: "2 / 2"
      page.driver.browser.action.send_keys(:escape).perform
      assert_no_selector ".image-lightbox-dialog"
      assert_equal link, page.evaluate_script("document.activeElement")
      assert_current_path path
    end
  end

  test "list and title images open the chat viewer without navigation" do
    visit collavre.creatives_path
    find("#creative-#{@creative.id} img[alt='Second']").click
    assert_selector ".image-lightbox-dialog[open] .image-lightbox-counter", text: "2 / 2"
    assert_no_selector ".image-lightbox-delete"
    assert_no_selector ".image-lightbox-download-one"
    find(".image-lightbox-prev").click
    assert_selector ".image-lightbox-counter", text: "1 / 2"
    find(".image-lightbox-zoom-in").click
    assert_match "scale(1.25)", find(".image-lightbox-image")[:style]
    find(".image-lightbox-close").click
    assert_no_selector ".image-lightbox-dialog"

    visit collavre.creatives_path(id: @creative.id)
    find(".creative-title-content img[alt='First']").click
    assert_selector ".image-lightbox-dialog[open] .image-lightbox-counter", text: "1 / 2"
    page.driver.browser.action.send_keys(:escape).perform
    assert_no_selector ".image-lightbox-dialog"
    assert_current_path collavre.creatives_path(id: @creative.id)
  end
end
