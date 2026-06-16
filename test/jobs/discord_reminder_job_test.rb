require "test_helper"

class DiscordReminderJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(discord_user_token: "tok", discord_channel_id: "555")
  end

  def with_client(configured:)
    fake = Object.new
    fake.define_singleton_method(:configured?) { configured }
    original = DiscordGroupClient.method(:for)
    DiscordGroupClient.define_singleton_method(:for) { |*_a, **_k| fake }
    yield
  ensure
    DiscordGroupClient.define_singleton_method(:for, original)
  end

  test "enqueues one digest for a configured workspace" do
    with_client(configured: true) do
      assert_enqueued_with(job: DiscordReminderDigestJob, args: [ @workspace.id ]) do
        DiscordReminderJob.perform_now
      end
    end
  end

  test "does not enqueue a digest when the client is not configured" do
    with_client(configured: false) do
      assert_no_enqueued_jobs(only: DiscordReminderDigestJob) do
        DiscordReminderJob.perform_now
      end
    end
  end

  test "skips workspaces without Discord token/channel" do
    @workspace.update!(discord_user_token: nil, discord_channel_id: nil)
    assert_no_enqueued_jobs(only: DiscordReminderDigestJob) do
      DiscordReminderJob.perform_now
    end
  end
end
