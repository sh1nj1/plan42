module SystemDragHelper
  include Html5DndHelpers
  def drag_and_drop_with_offset(source, target, x_offset, y_offset)
    html5_drag_by_offset(source, target, x_offset, y_offset)
  rescue StandardError => e
    perform_low_level_drag(source, target, x_offset, y_offset)
  end

  private

  def perform_low_level_drag(source, target, x_offset, y_offset)
    driver = page.driver.browser
    driver.action
          .move_to(source.native)
          .click_and_hold(source.native)
          .move_by(0, 5)
          .move_to(target.native, x_offset, y_offset)
          .release
          .perform
  end
end
