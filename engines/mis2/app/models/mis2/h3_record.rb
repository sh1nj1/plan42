module Mis2
  class H3Record < Mis2::ApplicationRecord
    self.abstract_class = true

    connects_to database: { writing: :h3, reading: :h3 }
  end
end
