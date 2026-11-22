# Reads Anthropic's prices into Models & prices once a day (SCRUM-70).
class AiPriceReadJob < ApplicationJob
  queue_as :default

  def perform
    AiPriceRead.new.call
  end
end
