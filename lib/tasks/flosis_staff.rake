namespace :flosis do
  namespace :staff do
    desc "Make the user with this email Flosis staff (the design library's keepers)"
    task :grant, [ :email ] => :environment do |_, args|
      user = FlosisStaff.grant!(args.fetch(:email))
      puts "#{user.email_address} is now Flosis staff"
    end

    desc "Take Flosis staff away from the user with this email"
    task :revoke, [ :email ] => :environment do |_, args|
      user = FlosisStaff.revoke!(args.fetch(:email))
      puts "#{user.email_address} is no longer Flosis staff"
    end
  end
end
