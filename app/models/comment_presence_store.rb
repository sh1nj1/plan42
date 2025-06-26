class CommentPresenceStore
  KEY_PREFIX = "comment_presence:"

  def self.add(creative_id, user_id)
    ids = list(creative_id)
    unless ids.include?(user_id)
      ids << user_id
      Rails.cache.write(key(creative_id), ids)
    end
    ids
  end

  def self.remove(creative_id, user_id)
    ids = list(creative_id)
    if ids.delete(user_id)
      Rails.cache.write(key(creative_id), ids)
    end
    ids
  end

  def self.list(creative_id)
    Rails.cache.read(key(creative_id)) || []
  end

  def self.key(creative_id)
    "#{KEY_PREFIX}#{creative_id}"
  end
end
