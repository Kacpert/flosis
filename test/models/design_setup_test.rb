require "test_helper"

# A setup run (the Designs setup, feature by feature): the steps the progress
# screen lists, how far along it is, the units a job claims, and the map it
# builds its features from.
class DesignSetupTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app@production" } ], design_repo: "acme/designs",
                     designs_ui_system: "tailwind", designs_ui_version: "4")
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
    @project.design_setup_roles.create!(name: "Member", login_url: "https://s.test/login", username: "m", password: "p", position: 1)
    @setup = DesignSetup.create!(project: @project, started_by: users(:one))
  end

  test "the steps before the map" do
    assert_equal [ "Reading acme/app @ production", "Signing in as Admin, Member", "Mapping features",
                   "Design system: tokens, fonts and icons from Tailwind 4", "Building features one by one",
                   "Committing to acme/designs @ master" ], @setup.steps.map(&:first)
    assert_equal [ 10, 2, 20, 30, 450, 3 ], @setup.steps.map(&:last)
    assert_equal 0, @setup.percent
  end

  test "the steps after the map" do
    @setup.add_features!([ { "name" => "App shell" }, { "name" => "Timesheet" }, { "name" => "Reports" } ])
    @setup.features.first.update!(status: "done")
    @setup.update!(step: 4)

    labels = @setup.steps.map(&:first)
    assert_equal "Mapping features: 3 found", labels[2]
    assert_equal "Building features one by one: 1 of 3 done", labels[4]
    assert_equal 60, @setup.steps[4].last
    assert_equal 63, @setup.minutes_left
    assert_equal 59, @setup.percent
  end

  test "a repository without a branch is read at its default one" do
    @project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" }, { "role" => "API", "repo" => "acme/api@main" } ])
    assert_equal "Reading acme/app, acme/api @ main", @setup.steps.first.first
  end

  test "the time left reads in hours once it is an hour or more" do
    assert_equal "About 6 h left", DesignSetup.time_left(360)
    assert_equal "About 9 h left", DesignSetup.time_left(515)
    assert_equal "About 40 min left", DesignSetup.time_left(40)
  end

  test "a finished step keeps the minutes it took" do
    travel_to(Time.zone.parse("2026-11-02 16:40")) { @setup.start_step! }
    travel_to(Time.zone.parse("2026-11-02 16:52")) { @setup.finish_step! }
    assert_equal [ 1, 12 ], [ @setup.step, @setup.minutes_taken(0) ]
    assert_nil @setup.minutes_taken(1)
  end

  test "a unit is claimed by one job at a time, until its deadline" do
    assert @setup.claim_unit!("job-a", limit: 1.hour)
    assert_not @setup.claim_unit!("job-b", limit: 1.hour)
    assert @setup.claim_unit!("job-a", limit: 1.hour), "the same job, delivered again, takes its unit over"
    travel 2.hours do
      assert @setup.claim_unit!("job-b", limit: 1.hour)
    end
    @setup.release_unit!("job-b")
    assert_nil @setup.reload.unit_job_id
  end

  test "only the job that holds the unit releases it, and a released run is found stalled until its next job takes it" do
    assert @setup.claim_unit!("job-a", limit: 1.hour)
    @setup.release_unit!("job-b")
    assert_equal "job-a", @setup.reload.unit_job_id
    @setup.release_unit!("job-a")
    assert_nil @setup.reload.unit_job_id
    assert_includes DesignSetup.stalled, @setup, "a run whose next job never came is picked up"
    assert @setup.claim_unit!("job-c", limit: 1.hour)
    assert_not_includes DesignSetup.stalled, @setup
  end

  test "a run whose unit outlived its deadline is stalled" do
    @setup.update!(unit_job_id: "job-a", unit_deadline_at: 1.minute.ago)
    finished = DesignSetup.create!(project: @project, status: "approved", unit_job_id: "job-b", unit_deadline_at: 1.minute.ago)
    live = DesignSetup.create!(project: @project, unit_job_id: "job-c", unit_deadline_at: 1.hour.from_now)
    stalled = DesignSetup.stalled.to_a
    assert_includes stalled, @setup
    assert_not_includes stalled, finished
    assert_not_includes stalled, live
  end

  test "the map's features keep dense positions and unique keys" do
    @setup.add_features!([
      { "name" => "Timesheet", "contexts" => %w[1-admin], "screens" => [ "Week" ], "brief" => "Week and month views.", "notes" => [ "No data." ] },
      { "name" => "Timesheet" },
      { "name" => "!!!" }
    ])
    features = @setup.features.to_a
    assert_equal [ 1, 2, 3 ], features.map(&:position)
    assert_equal %w[timesheet timesheet-2 feature], features.map(&:key)
    assert_equal [ %w[1-admin], [ "Week" ], "Week and month views.", [ "No data." ] ],
                 [ features.first.contexts, features.first.screens, features.first.brief, features.first.notes ]
  end

  test "two long names alike are two features" do
    long = "Workshop reporting for every developer across all the projects and their sprints"
    @setup.add_features!([ { "name" => long }, { "name" => long } ])
    assert_equal 2, @setup.features.map(&:key).uniq.size
  end

  test "a note is kept once" do
    @setup.note!("Signing in", "Member could not sign in.")
    @setup.note!("Signing in", "Member could not sign in.")
    assert_equal [ { "label" => "Signing in", "text" => "Member could not sign in." } ], @setup.reload.notes
  end

  test "the run's folder sits beside the project's designs" do
    assert_equal Pathname(@project.designs_dir).join("design-runs", @setup.id.to_s), @setup.run_dir
  end

  test "active setups" do
    @setup.update!(status: "approved")
    assert_not_includes DesignSetup.active, @setup
  end
end
