# The countries a company can bill from, for the Billing details select:
# ISO 3166 alpha-2 codes and English names (config/billing/countries.yml).
module Billing
  module Countries
    module_function

    def names
      @names ||= YAML.load_file(Rails.root.join("config/billing/countries.yml")).freeze
    end

    def codes
      names.keys
    end

    def name(code)
      names[code.to_s.upcase] || code.to_s.upcase
    end

    # [[name, code]], Poland first (most buyers), then by name.
    def options
      sorted = names.sort_by { |_, name| name }.map { |code, name| [ name, code ] }
      sorted.partition { |_, code| code == "PL" }.flatten(1)
    end
  end
end
