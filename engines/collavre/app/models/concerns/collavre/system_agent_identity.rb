# frozen_string_literal: true

module Collavre
  module SystemAgentIdentity
    extend ActiveSupport::Concern

    included do
      # Server-owned provenance, never accepted by registration/profile/AI params.
      attr_readonly :system_agent
      validates :email, exclusion: { in: [ Kollavy::EMAIL ] }, unless: :system_agent?
    end
  end
end
