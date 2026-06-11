# frozen_string_literal: true

module Collavre
  # A speakable, stable reference number that lets a human point at a pending
  # agent decision or session by voice ("1번 승인"). See the migration for why
  # this exists. Numbers are stable per (user, device) for the lifetime of the
  # underlying work and are not reused immediately after resolving (to avoid
  # "1번" suddenly meaning a different task between two utterances).
  class MobileVoiceRef < ApplicationRecord
    self.table_name = "mobile_voice_refs"

    KINDS    = %w[approval agent_session].freeze
    STATUSES = %w[active resolved].freeze

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    belongs_to :target_comment, class_name: "Collavre::Comment", optional: true

    validates :device_id, presence: true
    validates :ref_number, presence: true,
              uniqueness: { scope: [ :user_id, :device_id ] }
    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }

    scope :active,   -> { where(status: "active") }
    scope :resolved, -> { where(status: "resolved") }
    scope :for_device, ->(user_id, device_id) { where(user_id: user_id, device_id: device_id) }

    def resolve!
      update!(status: "resolved", last_seen_at: Time.current)
    end
  end
end
