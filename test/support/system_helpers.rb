module SystemHelpers
  PASSWORD = "P4ssW0rd!2"

  def sign_in_via_ui(user, password: PASSWORD)
    visit new_session_path
    fill_in placeholder: I18n.t("users.new.enter_your_email"), with: user.email
    fill_in placeholder: I18n.t("users.new.enter_your_password"), with: password
    find("#sign-in-submit").click
    assert_current_path root_path, ignore_query: true
  end

  def resize_window_to(width = 1200, height = 800)
    page.current_window.resize_to(width, height)
  rescue Capybara::NotSupportedByDriverError
    # Ignore for drivers that do not support resizing.
  end

  def wait_for_network_idle(timeout: Capybara.default_max_wait_time)
    start = Time.now
    while Time.now - start < timeout
      active = page.evaluate_script(<<~JS)
      window.__pendingXHRs = window.__pendingXHRs || 0;
      (function(){
        if (!window.__networkHooked) {
          const origOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function() {
            window.__pendingXHRs++;
            this.addEventListener('loadend', () => window.__pendingXHRs--);
            origOpen.apply(this, arguments);
          };
          window.__networkHooked = true;
        }
      })();
      window.__pendingXHRs
    JS

      break if active == 0
      sleep 0.05
    end
  end
end
