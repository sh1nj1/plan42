class VirtualCreativeHierarchy < ApplicationRecord
  belongs_to :ancestor, class_name: "Creative"
  belongs_to :descendant, class_name: "Creative"
  belongs_to :creative_link
end
