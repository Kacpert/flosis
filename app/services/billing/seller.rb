# Who issues Flosis's invoices (SCRUM-71): Ruby on SaaS Sp. z o.o., as it is
# registered in KSeF (Kacper, 2026-11-24). ENV INVOICE_SELLER_NAME,
# INVOICE_SELLER_NIP (or KSEF_NIP), INVOICE_SELLER_STREET,
# INVOICE_SELLER_POSTAL_CODE and INVOICE_SELLER_CITY override it, which the
# KSeF TEST environment needs (it takes fictional data only).
module Billing
  module Seller
    NAME = "Ruby on SaaS Sp. z o.o.".freeze
    NIP = "5242954651".freeze
    STREET = "ul. Dalanowska 46/117".freeze
    POSTAL_CODE = "03-566".freeze
    CITY = "Warszawa".freeze

    module_function

    def name = ENV["INVOICE_SELLER_NAME"].presence || NAME
    def nip = (ENV["INVOICE_SELLER_NIP"].presence || ENV["KSEF_NIP"].presence || NIP).delete("^0-9")
    def street = ENV["INVOICE_SELLER_STREET"].presence || STREET
    def postal_code = ENV["INVOICE_SELLER_POSTAL_CODE"].presence || POSTAL_CODE
    def city = ENV["INVOICE_SELLER_CITY"].presence || CITY

    def configured?
      [ name, nip, street, postal_code, city ].all?(&:present?)
    end

    # "Ruby on SaaS Sp. z o.o. · Warszawa, Poland", as the emails' foot says it.
    def footer
      "#{name} · #{city}, Poland"
    end
  end
end
