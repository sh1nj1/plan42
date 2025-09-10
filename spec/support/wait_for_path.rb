module WaitForPath
  def wait_for_path(path)
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop until current_path == path
    end
  end
end

RSpec.configure do |config|
  config.include WaitForPath, type: :system
end
