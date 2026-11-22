# AI cost figures on working screens (SCRUM-70): drawn only while the
# organization allows them (Configuration › AI) and the person has turned
# them on (Profile). Consumption ignores both.
module AiCostsHelper
  def ai_costs_visible?
    current_workspace&.ai_costs_enabled? && current_user&.show_ai_costs? ? true : false
  end

  # One area's figures for a page of records, in one query; nothing (and no
  # query) while costs are not shown.
  def ai_figures(records, area:)
    return {} unless ai_costs_visible?

    AiCosts.new(current_workspace).item_figures(records, area: area)
  end

  # The record's figure from AiCosts#item_figures, formatted; nil when costs
  # are not shown or it has no runs.
  def ai_item_cost(figures, record)
    return unless record && ai_costs_visible?

    AiCostFormatter.item(figures&.[]([ record.class.polymorphic_name, record.id ]))
  end
end
