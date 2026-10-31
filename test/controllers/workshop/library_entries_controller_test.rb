require "test_helper"

class Workshop::LibraryEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @entry = LibraryEntry.create!(kind: "skill", key: "forms", name: "Forms").tap { _1.revise!(body: "Label inputs.", by: nil) }
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: projects(:jira_project).id }
  end

  test "a workspace admin who isn't staff gets a 404" do
    get workshop_library_entries_path
    assert_response :not_found
    get workshop_library_entry_path(@entry)
    assert_response :not_found
  end

  test "someone who isn't staff cannot change the library either" do
    patch workshop_library_entry_path(@entry), params: { library_entry: { name: "Forms", body: "Changed." } }
    assert_response :not_found
    post workshop_library_entries_path, params: { library_entry: { kind: "skill", key: "x", name: "X", body: "x" } }
    assert_response :not_found
    post restore_workshop_library_entry_path(@entry), params: { version_id: @entry.current_version.id }
    assert_response :not_found
    assert_equal [ "Label inputs." ], @entry.library_entry_versions.pluck(:body)
    assert_not LibraryEntry.exists?(key: "x")
  end

  test "staff see the library grouped by kind" do
    users(:one).update!(flosis_staff: true)
    get workshop_library_entries_path
    assert_response :success
    assert_select "h2", /Skills/
    assert_select "body", /Forms/
  end

  test "staff create an entry with its first version" do
    users(:one).update!(flosis_staff: true)
    post workshop_library_entries_path,
         params: { library_entry: { kind: "style_pack", key: "calm", name: "Calm", description: "Quiet", body: "Generous whitespace." } }
    entry = LibraryEntry.find_by!(key: "calm")
    assert_redirected_to workshop_library_entry_path(entry)
    assert_equal [ "style_pack", "Generous whitespace.", users(:one) ],
                 [ entry.kind, entry.current_version.body, entry.current_version.created_by ]
  end

  test "an entry without its text is not created" do
    users(:one).update!(flosis_staff: true)
    post workshop_library_entries_path, params: { library_entry: { kind: "skill", key: "empty", name: "Empty", body: " " } }
    assert_response :unprocessable_entity
    assert_not LibraryEntry.exists?(key: "empty")
  end

  test "staff editing an entry adds a version" do
    users(:one).update!(flosis_staff: true)
    patch workshop_library_entry_path(@entry), params: { library_entry: { name: "Forms", body: "Label inputs. Inline errors." } }
    assert_equal 2, @entry.reload.current_version.number
  end

  # A project names its style pack by key, and a turn's record by version:
  # neither may change under them.
  test "an entry's key and kind stay as they were made" do
    users(:one).update!(flosis_staff: true)
    patch workshop_library_entry_path(@entry),
          params: { library_entry: { name: "Forms", key: "renamed", kind: "style_pack", body: "Label inputs." } }
    assert_equal [ "forms", "skill" ], [ @entry.reload.key, @entry.kind ]
  end

  test "staff restore an old version" do
    users(:one).update!(flosis_staff: true)
    v1 = @entry.current_version
    @entry.revise!(body: "changed", by: users(:one))
    post restore_workshop_library_entry_path(@entry), params: { version_id: v1.id }
    assert_equal "Label inputs.", @entry.reload.current_version.body
  end

  test "an entry's page lists its versions, newest first, each but the current one with Restore" do
    users(:one).update!(flosis_staff: true)
    @entry.revise!(body: "changed", by: users(:one))
    get workshop_library_entry_path(@entry)
    assert_response :success
    assert_select "[data-version]" do |versions|
      assert_equal %w[2 1], versions.map { _1["data-version"] }
    end
    assert_select "form[action=?]", restore_workshop_library_entry_path(@entry), count: 1
  end

  test "there is no destroy route" do
    users(:one).update!(flosis_staff: true)
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(workshop_library_entry_path(@entry), method: :delete)
    end
  end

  test "the sidebar links the Library for staff only" do
    get workshop_pipeline_path
    assert_select "a[href=?]", workshop_library_entries_path, count: 0
    users(:one).update!(flosis_staff: true)
    get workshop_pipeline_path
    assert_select "a[href=?]", workshop_library_entries_path
  end
end
