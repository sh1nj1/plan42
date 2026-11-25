module Collavre
  class OnboardingReplaysController < ApplicationController
    def create
      Notices::OnboardingReplay.call(Current.user)
      keys = NoticeRegistry.group(:onboarding).select(&:mission?).map(&:key)
      Notices::Tracker.broadcast(Current.user, changed: keys)
      redirect_to creatives_path, status: :see_other, notice: t("collavre.notices.replay.restarted")
    end
  end
end
