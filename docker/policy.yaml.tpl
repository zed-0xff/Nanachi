version: 1

filesystem_policy:
  include_workdir: true
  read_only:
    - /bin
    - /usr
    - /lib
    - /proc
    - /dev/urandom
    - /etc
    - /var/log
  read_write:
    - /tmp
    - /dev/null

landlock:
  compatibility: best_effort

network_policies:
  hyperqwen:
    name: hyperqwen
    endpoints:
      - host: hyperqwen-host
        port: 18020
    binaries:
      - path: /**

  github_readonly:
    name: github_readonly
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only
    binaries:
      - path: /**

  npm_registry:
    endpoints:
      - host: registry.npmjs.org
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only
        allow_encoded_slash: true
    binaries:
      - path: /**
