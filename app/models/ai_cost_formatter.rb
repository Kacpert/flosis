# How AI money and tokens read on screen (SCRUM-70), in US dollars.
module AiCostFormatter
  module_function

  def money(amount)
    "$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', amount.to_d.round(2)))}"
  end

  # A sum of runs: "unknown" when there were runs and none reported a cost.
  def sum(amount, runs:, priced:)
    runs.to_i.positive? && priced.to_i.zero? ? "unknown" : money(amount)
  end

  # An item's figure: its total, with this month in brackets only when that is
  # a different amount. "unknown" when none of its runs reported a cost; nil
  # when it has no runs at all.
  def item(figure)
    return if figure.nil? || figure.runs.zero?
    return "unknown" if figure.priced_runs.zero?

    total = figure.total.to_d.round(2)
    month = figure.this_month.to_d.round(2)
    return money(total) if month == total
    return "#{money(total)} (none this month)" if month.zero?

    "#{money(total)} (#{money(month)} this month)"
  end

  # "184k in · 12.4k out · 96k cache" (cache = reads and writes).
  def tokens(run)
    "#{count(run.input_tokens)} in · #{count(run.output_tokens)} out · #{count(run.cache_tokens)} cache"
  end

  def count(tokens)
    tokens = tokens.to_i
    return "0" if tokens.zero?
    return "#{trim((tokens / 1_000_000.0).round(1))}M" if tokens >= 999_950

    thousands = (tokens / 1000.0).round(1)
    thousands = thousands.round if thousands >= 100
    "#{trim(thousands)}k"
  end

  def trim(number)
    number.to_s.delete_suffix(".0")
  end
end
