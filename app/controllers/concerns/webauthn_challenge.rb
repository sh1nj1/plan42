module WebauthnChallenge
  extend ActiveSupport::Concern

  private

  def store_challenge(key, challenge)
    session[key] = challenge
  end

  def consume_challenge(key)
    session.delete(key)
  end
end
