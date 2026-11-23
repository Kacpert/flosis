require "securerandom"

module Ksef
  # Polish NIP (tax id) checks: the checksum KSeF verifies on production, and
  # random valid numbers for the TEST environment, which must only ever see
  # fictional companies.
  module Nip
    WEIGHTS = [ 6, 5, 7, 2, 3, 4, 5, 6, 7 ].freeze
    # FA(3)'s TNrNIP pattern: no leading zero, digits 2–3 not both zero.
    FORMAT = /\A[1-9]((\d[1-9])|([1-9]\d))\d{7}\z/

    def self.valid?(nip)
      digits = nip.to_s
      return false unless digits.match?(FORMAT)

      checksum(digits[0, 9]) == digits[9].to_i
    end

    def self.random
      loop do
        body = "#{SecureRandom.random_number(1..9)}#{format('%08d', SecureRandom.random_number(100_000_000))}"
        sum = checksum(body)
        next if sum == 10

        nip = "#{body}#{sum}"
        return nip if valid?(nip)
      end
    end

    def self.checksum(nine_digits)
      nine_digits.chars.each_with_index.sum { |digit, i| digit.to_i * WEIGHTS[i] } % 11
    end
  end
end
