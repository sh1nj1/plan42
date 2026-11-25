require_relative "../application_system_test_case"

class CreativeListFileDropTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "file-drop@example.com", password: SystemHelpers::PASSWORD,
                         name: "File Drop", email_verified_at: Time.current)
    @target = Creative.create!(description: "File drop target", user: @user)
    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creatives_path
    assert_selector "#creative-#{@target.id}"
  end

  test "center appends and edge drops create siblings with visible attachments" do
    drop_file(0.5, "center.txt")
    assert_selector "#creative-#{@target.id} a[download='center.txt']", wait: 10
    %w[before after].each_with_index do |position, index|
      filename = "#{position}.txt"
      drop_file(index.zero? ? 0.05 : 0.95, filename)
      assert_selector "creative-tree-row a[download='#{filename}']", wait: 10
      sibling = Creative.where(user: @user).where.not(id: @target.id).order(:id).last
      assert_nil sibling.parent_id
      assert_equal 1, sibling.files.count
      order = Creative.where(id: [ sibling.id, @target.id ]).order(:sequence).pluck(:id)
      assert_equal(index.zero? ? [ sibling.id, @target.id ] : [ @target.id, sibling.id ], order)
    end
  end

  private

  def drop_file(ratio, filename)
    execute_script(<<~JS, @target.id, ratio, filename)
      const tree = document.getElementById(`creative-${arguments[0]}`);
      const rect = tree.getBoundingClientRect();
      const transfer = new DataTransfer();
      transfer.items.add(new File(['attachment bytes'], arguments[2], { type: 'text/plain' }));
      const options = { bubbles: true, cancelable: true, dataTransfer: transfer,
        clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height * arguments[1] };
      tree.dispatchEvent(new DragEvent('dragover', options));
      tree.dispatchEvent(new DragEvent('drop', options));
    JS
  end
end
