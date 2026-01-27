module Collavre
  module UserExtensions
    extend ActiveSupport::Concern

    included do
      # Core Collavre associations
      has_many :collavre_creatives, class_name: "Collavre::Creative", dependent: :destroy
      has_many :collavre_comments, class_name: "Collavre::Comment", dependent: :destroy
      has_many :collavre_creative_shares, class_name: "Collavre::CreativeShare", dependent: :destroy
      has_many :collavre_shared_creative_shares, class_name: "Collavre::CreativeShare",
               foreign_key: :shared_by_id, dependent: :nullify, inverse_of: :shared_by
      has_many :collavre_topics, class_name: "Collavre::Topic", dependent: :destroy
      has_many :collavre_inbox_items, class_name: "Collavre::InboxItem",
               foreign_key: :owner_id, dependent: :destroy, inverse_of: :owner
      has_many :collavre_invitations, class_name: "Collavre::Invitation",
               foreign_key: :inviter_id, dependent: :destroy, inverse_of: :inviter
      has_many :collavre_contacts, class_name: "Collavre::Contact", dependent: :destroy
      has_many :collavre_contact_memberships, class_name: "Collavre::Contact",
               foreign_key: :contact_user_id, dependent: :destroy, inverse_of: :contact_user
      has_many :collavre_user_themes, class_name: "Collavre::UserTheme", dependent: :destroy
      has_many :collavre_devices, class_name: "Collavre::Device", dependent: :destroy
      has_many :collavre_calendar_events, class_name: "Collavre::CalendarEvent", dependent: :destroy
      has_many :collavre_labels, class_name: "Collavre::Label", foreign_key: :owner_id, dependent: :destroy
      has_many :collavre_activity_logs, class_name: "Collavre::ActivityLog", dependent: :destroy
      has_many :collavre_comment_read_pointers, class_name: "Collavre::CommentReadPointer", dependent: :destroy
      has_many :collavre_creative_expanded_states, class_name: "Collavre::CreativeExpandedState", dependent: :destroy
    end
  end
end
