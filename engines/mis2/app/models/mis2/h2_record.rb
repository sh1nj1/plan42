module Mis2
  class H2Record < Mis2::ApplicationRecord
    self.abstract_class = true

    connects_to database: { writing: :h2, reading: :h2 }
  end
end
