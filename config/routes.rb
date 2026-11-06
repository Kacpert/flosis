Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resource :registration, only: [ :new, :create ]

  resources :workspaces, only: [ :new, :create ] do
    member do
      post :switch
    end
  end

  # Workspace-scoped routes. Root redirects to the current product's landing.
  root "home#index"

  post "product/switch", to: "products#switch", as: :switch_product
  post "workshop/switch_project", to: "products#switch_project", as: :switch_workshop_project

  resource :profile, only: [ :show, :update ]
  resources :workspace_members, only: [ :index, :new, :create, :edit, :update, :destroy ] do
    member do
      post :become
    end
  end
  post :stop_impersonating, to: "workspace_members#stop_impersonating"

  resources :clients
  resource :workspace_settings, only: [ :show, :update ]
  resources :discord_reminder_recipients, only: [ :create, :update, :destroy ]
  resources :feedback_meetings
  resources :projects do
    resources :tasks, only: [ :create, :destroy ], shallow: true
    resources :project_memberships, only: [ :create, :update, :destroy ], path: "members"
    member do
      patch :archive
      patch :unarchive
      get :jira_tasks, to: "jira#jira_tasks"
      post :jira_sync, to: "jira#sync"
    end
  end
  resources :tags

  resources :holiday_requests, only: [:index, :new, :create] do
    member do
      patch :approve
      patch :cancel
    end
  end

  resources :holiday_balance_entries, only: [:index, :new, :create]

  resources :time_entries do
    collection do
      post :bulk_update
      post :bulk_destroy
    end
  end

  # Personal-access-token JSON API (Api::V1::BaseController): list and book
  # hours, delete recent ones, list the projects they can go on. Nothing else.
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      resources :projects, only: [ :index ]
      resources :time_entries, only: [ :index, :create, :destroy ]
    end
  end

  resource :timer, only: [] do
    post :start
    patch :stop
    patch :update_running
    delete :discard
  end

  resource :timesheet, only: [ :show ] do
    patch :update_cell
    get :month
  end

  namespace :reports do
    resource :summary, only: [ :show ] do
      get :export_csv
      get :export_pdf
    end
    resource :detailed, only: [ :show ] do
      get :export_csv
      get :export_pdf
    end
    resource :weekly, only: [ :show ] do
      get :export_csv
      get :export_pdf
    end
    resource :project_report, only: [ :show ]
  end

  # API endpoints for dynamic UI
  get "projects/:project_id/tasks_list", to: "tasks#list", as: :project_tasks_list

  # Workshop: Idea → Brief pipeline (and Brief → Task relocation)
  get  "workshop",                 to: "workshop#index",    as: :workshop
  get  "workshop/new_idea",        to: "workshop#new_idea", as: :new_idea_workshop
  post "workshop/start",           to: "workshop#start",    as: :start_workshop
  get  "workshop/tasks/:id/brief", to: "workshop#brief",    as: :workshop_brief

  # Workshop redesign (Clar): Create Tasks pipeline + idea intake. Additive —
  # more routes (advance/save_locally/push_jira, versions, design_request,
  # process/reporting/bugs/configuration) land in later phases (design_request
  # landed in Task 5.3).
  namespace :workshop do
    get "pipeline", to: "pipeline#index", as: :pipeline
    get "designs", to: "designs_module#show", as: :designs_overview
    post "ideas/:id/design_thread", to: "design_threads#start_from_task", as: :start_idea_design_thread
    resource :design_setup_run, only: %i[new create edit update show], path: "designs/setup", controller: "design_setup_runs" do
      post :retry
      post :reimport
    end
    # Designs imports: an import's page lives in Designs (tab=imports); what
    # the person does there posts here.
    resources :design_imports, only: :create, path: "designs/imports" do
      member { post :retry_all; post :add_feature }
      resources :features, only: [], controller: "design_import_features" do
        member { post :retry; post :reply; post :set_aside; post :accept; post :reject; post :revise }
      end
    end
    resources :design_threads, only: %i[create destroy], path: "designs/threads" do
      member { post :message; post :merge; post :update_description; post :update_master; post :create_task; post :attach; post :restore }
    end
    get "jira_browser", to: "jira_browser#show", as: :jira_browser
    resources :ideas, only: [ :create, :show, :update, :destroy ] do
      member { post :advance; post :save_locally; post :push_jira; post :sync_jira; post :estimate; post :spin_off }
      resources :versions, only: [ :create, :update, :destroy ] do
        member { post :make_current }
      end
      resource :design_request, only: [ :create, :update, :destroy ]
    end
    # The design library, for Flosis staff only. Entries are switched off,
    # never deleted: turns record the versions they ran on.
    resources :library_entries, path: "library", except: :destroy do
      member { post :restore }
    end
    get "process", to: "process#show", as: :process
    get "reporting", to: "reports#show", as: :reporting
    get "reporting/developer/:id", to: "reports#developer", as: :developer_report
    get "bugs", to: "bugs#show", as: :bugs
    post "bugs/:jira_key/analyze", to: "bugs#analyze", as: :analyze_bug, constraints: { jira_key: /[^\/]+/ }
    resources :alert_rules, only: [ :create, :update, :destroy ] do
      collection { patch :reorder }
      member { get :history; get :memory; post :clear_memory; post :clear_ai_issues; patch :toggle_active; post :run_now }
    end
    get "configuration", to: "configuration#show", as: :configuration
    patch "configuration", to: "configuration#update"
    post "configuration/test_github", to: "configuration#test_github", as: :test_github_configuration
    post "configuration/verify_jira_fields", to: "configuration#verify_jira_fields", as: :verify_jira_fields_configuration
    post "configuration/refresh_features", to: "configuration#refresh_features", as: :refresh_features_configuration
    resources :discord_webhooks, only: [ :create, :destroy ]
    resources :project_members, only: [ :create, :update, :destroy ]
    resources :projects, only: [ :create ]
  end

  # Jira integration
  get "jira/projects", to: "jira#projects", as: :jira_projects

  resources :jira_tasks, only: [:index, :show] do
    collection do
      get :board_data
      post :refresh
    end
    resources :task_drafts, only: [:index]
    resource :chat_session, only: [:create, :show, :destroy] do
      post :message
    end

    # Estimate & breakdown: two-panel page + its own chat + versioned results
    get :breakdown, to: "task_breakdowns#show"
    post :breakdown_update_jira, to: "task_breakdowns#update_jira"
    resources :task_breakdowns, only: [:index]
    resource :breakdown_chat_session, only: [:create, :show, :destroy] do
      post :message
    end

    # Workshop: brief conversation + versioned briefs + commit-to-Jira
    resource :brief_chat_session, only: [:create, :show, :destroy] do
      post :message
    end
    resources :briefs, only: [] do
      member { post :commit, to: "brief_commits#commit" }
    end
  end

  # Flosis's own back office, for Flosis staff only (users.flosis_staff):
  # organizations (workspaces), the people in them, and a few counts. Everyone
  # else gets a 404.
  namespace :hidmin do
    root "dashboard#show"
    resources :workspaces, path: "organizations", only: %i[index show new create update] do
      resources :memberships, only: %i[create update destroy] do
        member { post :resend_invitation }
      end
    end
    resources :users, path: "people", only: %i[index show update]
  end

  get "up" => "rails/health#show", as: :rails_health_check

  # A project's designs (Designs::Publisher). The lasting links ask whoever
  # opens them to sign in: /<organization>/<project>/design/<page> for master,
  # /<organization>/<project>/<key>/design/<page> for a task's approved
  # version. Each sends its reader on to the same page under a grant, served
  # sandboxed: /<organization>/<project>/<grant>/design/<page>. Last, so that
  # no page of the app is ever taken for one.
  scope ":organization/:project", format: false do
    get ":grant/design(/*path)", to: "designs/previews#show", constraints: { grant: Designs::PreviewGrant::FORMAT }
    get "design(/*path)", to: "designs/preview_entries#master"
    get ":key/design(/*path)", to: "designs/preview_entries#task", constraints: { key: /[A-Za-z0-9_-]+/ }
  end
end
