Rails.application.routes.draw do
  mount ExampleCustom::Engine => "/example_custom"
end
