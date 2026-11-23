# SCRUM-71: organizations pay for their AI plan upfront by card (Stripe keeps
# the card, Flosis computes every amount), buy top-ups, and get an invoice that
# goes through KSeF once a charge succeeds. All money is in US dollars.
# Production is MariaDB: no partial indexes, no jsonb.
class CreateBilling < ActiveRecord::Migration[8.1]
  def up
    create_table :billing_accounts do |t|
      t.references :workspace, null: false, foreign_key: true, index: { unique: true }
      # What every invoice is made out to; the country and VAT number decide its VAT.
      t.string :company_name
      t.string :street
      t.string :postal_code
      t.string :city
      t.string :country_code, limit: 2
      t.string :vat_number
      t.datetime :vat_checked_at
      # The card lives on Stripe; Flosis keeps only what it shows.
      t.string :stripe_customer_id
      t.string :stripe_payment_method_id
      t.string :card_brand
      t.string :card_last4
      t.integer :card_exp_month
      t.integer :card_exp_year
      # none · pending (chosen, not activated) · active · cancelling (until the
      # paid month ends) · ended. workspaces.ai_plan_id stays the current plan.
      t.string :plan_state, null: false, default: "none"
      t.references :pending_ai_plan, foreign_key: { to_table: :ai_plans, on_delete: :nullify }
      t.date :plan_started_on
      t.date :plan_ends_on
      t.boolean :auto_top_up, null: false, default: false
      t.decimal :auto_top_up_usd, precision: 12, scale: 2, null: false, default: 100
      t.date :usage_80_notified_on
      t.datetime :paused_notified_at
      t.timestamps
    end

    create_table :billing_charges do |t|
      t.references :workspace, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.references :ai_plan, foreign_key: { on_delete: :nullify }
      t.string :plan_name
      t.decimal :plan_price_usd, precision: 12, scale: 2
      t.date :period_month
      t.date :period_from
      t.date :period_to
      t.decimal :net_usd, precision: 12, scale: 2, null: false
      t.decimal :vat_usd, precision: 12, scale: 2, null: false
      t.decimal :gross_usd, precision: 12, scale: 2, null: false
      t.decimal :vat_rate, precision: 5, scale: 2
      t.string :vat_treatment, null: false
      t.string :stripe_payment_intent_id
      t.string :failure_message
      t.integer :attempts, null: false, default: 0
      t.datetime :first_failed_at
      t.date :next_retry_on
      t.datetime :paused_notified_at
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :succeeded_at
      t.timestamps
      t.index [ :workspace_id, :kind, :period_month ]
      t.index [ :workspace_id, :status ]
      t.index :stripe_payment_intent_id
    end

    create_table :invoices do |t|
      t.references :workspace, null: false, foreign_key: true, index: false
      t.references :billing_charge, null: false, foreign_key: true, index: { unique: true }
      t.string :number, null: false
      t.date :issued_on, null: false
      t.date :sold_on, null: false
      t.string :kind, null: false
      t.string :line_name, null: false
      t.string :buyer_name, null: false
      t.string :buyer_street
      t.string :buyer_postal_code
      t.string :buyer_city
      t.string :buyer_country_code, limit: 2, null: false
      t.string :buyer_vat_number
      t.decimal :net_usd, precision: 12, scale: 2, null: false
      t.decimal :vat_usd, precision: 12, scale: 2, null: false
      t.decimal :gross_usd, precision: 12, scale: 2, null: false
      t.decimal :vat_rate, precision: 5, scale: 2
      t.string :vat_treatment, null: false
      t.decimal :exchange_rate, precision: 10, scale: 4
      t.date :exchange_rate_date
      t.string :exchange_rate_table
      t.decimal :vat_pln, precision: 12, scale: 2
      t.string :ksef_status, null: false, default: "pending"
      t.string :ksef_number
      t.string :ksef_error
      t.string :ksef_reference
      t.integer :ksef_attempts, null: false, default: 0
      t.datetime :ksef_sent_at
      t.text :ksef_xml
      t.datetime :emailed_at
      t.timestamps
      t.index :number, unique: true
      t.index [ :workspace_id, :issued_on ]
      t.index :ksef_status
    end

    # Invoice numbers are gap-free within a month: the month's row is locked
    # while the next number is taken.
    create_table :invoice_counters do |t|
      t.date :month, null: false
      t.integer :last_number, null: false, default: 0
      t.timestamps
      t.index :month, unique: true
    end

    # plan: counts toward the month's limit · top_up: paid from the balance at
    # cost + 30% · free: no running plan · legacy: ran before billing started.
    add_column :ai_runs, :funding, :string
    add_index :ai_runs, [ :workspace_id, :funding, :ran_at ]
    execute "UPDATE ai_runs SET funding = 'legacy'"

    # A month paid from a day after the 1st reads "of $110.00 · 20–30 Nov".
    add_column :ai_month_limits, :starts_on, :date
  end

  def down
    remove_column :ai_month_limits, :starts_on
    remove_index :ai_runs, [ :workspace_id, :funding, :ran_at ]
    remove_column :ai_runs, :funding
    drop_table :invoice_counters
    drop_table :invoices
    drop_table :billing_charges
    drop_table :billing_accounts
  end
end
