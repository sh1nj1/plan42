# Isolates NoticeRegistry per test: registers only what a test declares and
# restores the engine's onboarding missions afterwards.
module NoticeTestHelpers
  def isolate_notice_registry
    Collavre::NoticeRegistry.reset!
  end

  def restore_notice_registry
    Collavre::NoticeRegistry.reset!
    Collavre::OnboardingNotices.register
  end

  def create_notice_user(name = "Newcomer")
    Collavre::User.create!(email: "#{name.downcase}-#{SecureRandom.hex(4)}@example.com", name: "#{name} #{SecureRandom.hex(2)}",
                           password: TEST_PASSWORD, password_confirmation: TEST_PASSWORD)
  end
end
