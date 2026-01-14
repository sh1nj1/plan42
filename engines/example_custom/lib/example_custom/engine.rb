module ExampleCustom
  class Engine < ::Rails::Engine
    isolate_namespace ExampleCustom
  end
end
