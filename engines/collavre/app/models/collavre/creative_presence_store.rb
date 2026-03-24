module Collavre
  class CreativePresenceStore
    KEY_PREFIX = "creative_presence:"

    def self.add(root_id, user_id)
      ids = list(root_id)
      unless ids.include?(user_id)
        ids << user_id
        Rails.cache.write(key(root_id), ids)
      end
      ids
    end

    def self.remove(root_id, user_id)
      ids = list(root_id)
      if ids.delete(user_id)
        Rails.cache.write(key(root_id), ids)
      end
      ids
    end

    def self.list(root_id)
      Rails.cache.read(key(root_id)) || []
    end

    def self.key(root_id)
      "#{KEY_PREFIX}#{root_id}"
    end
  end
end
