# Backward compatibility - includes Collavre::CreativesHelper
require "base64"
require "securerandom"
require "nokogiri"

module CreativesHelper
  include Collavre::CreativesHelper
end
