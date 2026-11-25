module Collavre
  # Engines register profile attributes alongside their profile view extensions.
  module ProfilePreferences
    def self.register(key, *attributes)
      registrations[key] = attributes.map(&:to_sym).freeze
    end

    def self.attributes
      registrations.values.flatten.uniq
    end

    def self.registrations
      @registrations ||= {}
    end
    private_class_method :registrations
  end
end
