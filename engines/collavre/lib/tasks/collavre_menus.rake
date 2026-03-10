# frozen_string_literal: true

namespace :collavre do
  desc "Seed menu items from Creative records"
  task seed_menus: :environment do
    require_relative "../../db/seeds/menu_seeds"
    Collavre::Seeds::MenuSeeds.seed!
    puts "Menu seeds created successfully"
  end
end
