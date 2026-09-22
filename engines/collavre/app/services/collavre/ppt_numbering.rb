module Collavre
  # Counters belong to one text body, including independent table cells and notes.
  module PptNumbering
    private

    def render_paragraphs(body, namespaces)
      counters = {}
      return [] unless body

      body.xpath("./a:p", namespaces).filter_map { |paragraph| render_paragraph(paragraph, namespaces, counters) }
    end

    def paragraph_marker(paragraph, properties, namespaces, counters)
      level = properties&.[]("lvl").to_i.clamp(0, 8)
      counters.delete_if { |key, _| key > level }
      numbering = properties&.at_xpath("./a:buAutoNum", namespaces)
      unless numbering
        counters.delete(level)
        return properties&.at_xpath("./a:buChar", namespaces)&.[]("char")
      end

      type = numbering["type"].to_s
      previous = counters[level]
      restart = paragraph.at_xpath("./a:pPr/a:buAutoNum", namespaces)&.[]("startAt")
      number = previous && previous.first == type && !restart ? previous.last + 1 : numbering["startAt"].to_i.clamp(1, 32_767)
      counters[level] = [ type, number ]
      numbered_marker(type, number)
    end

    def numbered_marker(type, number)
      value = case type
      when /\Aalpha/ then alphabetic_number(number)
      when /\Aroman/ then roman_number(number)
      else number.to_s
      end
      value = value.downcase if type.include?("Lc")
      case type
      when /ParenBoth\z/ then "(#{value})"
      when /ParenR\z/ then "#{value})"
      when /Plain\z/ then value
      else "#{value}."
      end
    end

    def alphabetic_number(number)
      result = +""
      while number.positive?
        number, remainder = (number - 1).divmod(26)
        result.prepend((65 + remainder).chr)
      end
      result
    end

    def roman_number(number)
      result = +""
      { 1000 => "M", 900 => "CM", 500 => "D", 400 => "CD", 100 => "C", 90 => "XC", 50 => "L", 40 => "XL", 10 => "X", 9 => "IX", 5 => "V", 4 => "IV", 1 => "I" }.each do |value, symbol|
        count, number = number.divmod(value)
        result << symbol * count
      end
      result
    end
  end
end
