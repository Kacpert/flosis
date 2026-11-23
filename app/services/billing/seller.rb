# Who issues Flosis's invoices (SCRUM-71): the Polish company, from ENV
# INVOICE_SELLER_NAME, INVOICE_SELLER_NIP (falls back to KSEF_NIP),
# INVOICE_SELLER_STREET, INVOICE_SELLER_POSTAL_CODE and INVOICE_SELLER_CITY.
module Billing
  module Seller
    module_function

    def name = ENV["INVOICE_SELLER_NAME"].presence
    def nip = (ENV["INVOICE_SELLER_NIP"].presence || ENV["KSEF_NIP"].presence)&.delete("^0-9")
    def street = ENV["INVOICE_SELLER_STREET"].presence
    def postal_code = ENV["INVOICE_SELLER_POSTAL_CODE"].presence
    def city = ENV["INVOICE_SELLER_CITY"].presence

    def configured?
      [ name, nip, street, postal_code, city ].all?(&:present?)
    end

    # "Flosis Sp. z o.o. · Warszawa, Poland", as the emails' foot says it.
    def footer
      [ name || "Flosis", [ city, "Poland" ].compact.join(", ") ].join(" · ")
    end
  end
end
