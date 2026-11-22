require "test_helper"

# SCRUM-70: Models & prices — read daily, typed by hand when a read fails.
class Hidmin::AiModelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
    @opus = AiModel.create!(model_id: "claude-opus-5-5", name: "Claude Opus 5.5", input_usd_per_mtok: 15, output_usd_per_mtok: 75,
                            read_at: Time.current)
  end

  test "the list shows each model's prices and which a plan uses" do
    ai_plans(:scale).ai_models << @opus
    get hidmin_ai_models_path
    assert_response :success
    assert_select "input[name=input_usd_per_mtok][value='15.0']"
    assert_includes response.body, "IN USE"
  end

  test "a typed price is saved and marked by hand" do
    patch hidmin_ai_model_path(@opus), params: { field: "output_usd_per_mtok", value: "80" }, as: :json
    assert_response :no_content
    @opus.reload
    assert_equal BigDecimal("80"), @opus.output_usd_per_mtok
    assert_equal "hand", @opus.price_source
    assert @opus.hand_set_at
  end

  test "only the four price fields can be typed" do
    patch hidmin_ai_model_path(@opus), params: { field: "model_id", value: "x" }, as: :json
    assert_response :unprocessable_entity
    assert_equal "claude-opus-5-5", @opus.reload.model_id
  end

  test "Read now reports how many prices were updated" do
    original = AiPriceRead.instance_method(:call)
    AiPriceRead.define_method(:call) { { updated: 3, failed: 1 } }
    post read_hidmin_ai_models_path
    assert_redirected_to hidmin_ai_models_path
    assert_equal "3 of 4 prices updated", flash[:clar_toast]
  ensure
    AiPriceRead.define_method(:call, original)
  end
end
