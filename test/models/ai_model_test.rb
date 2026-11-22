require "test_helper"

class AiModelTest < ActiveSupport::TestCase
  test "names models the way people say them" do
    assert_equal "Claude Opus 5.5", AiModel.name_for("claude-opus-5-5")
    assert_equal "Claude Haiku 4.5", AiModel.name_for("claude-haiku-4-5-20251001")
    assert_equal "Claude Opus 5", AiModel.name_for("claude-opus-5")
  end

  test "normalize_id drops the context suffix" do
    assert_equal "claude-opus-5", AiModel.normalize_id("claude-opus-5[1m]")
    assert_nil AiModel.normalize_id(nil)
  end

  test "seed makes the current family once" do
    AiModel.seed!
    AiModel.seed!
    assert_equal %w[claude-haiku-5-5 claude-opus-5-5 claude-sonnet-5-5], AiModel.order(:model_id).pluck(:model_id)
    assert_equal "Claude Opus 5.5", AiModel.find_by(model_id: "claude-opus-5-5").name
  end

  test "register adds a model once and ignores nothing" do
    AiModel.register!("claude-opus-5[1m]")
    AiModel.register!("claude-opus-5")
    AiModel.register!(nil)
    assert_equal [ "claude-opus-5" ], AiModel.pluck(:model_id)
  end

  test "a model is in use when a plan includes it" do
    model = AiModel.create!(model_id: "claude-opus-5-5", name: "Claude Opus 5.5")
    refute model.in_use?
    ai_plans(:scale).ai_models << model
    assert model.reload.in_use?
  end
end
