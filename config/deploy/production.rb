server "host420646.hostido.net.pl",
  user: "host420646",
  roles: %w[app db web],
  ssh_options: {
    port: 64321,
    forward_agent: true,
    auth_methods: %w[publickey password]
  }
