# gateway spec 共享 helper（原 gateway_spec.cr 顶层定义，多 spec 文件共用）。
def wait_for(seconds : Time::Span = 10.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

def gateway_tmp_dir(name : String) : Path
  dir = Path[Dir.tempdir, "sebas-gateway-spec", "#{name}-#{Random::Secure.hex(4)}"]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

def gw_test_config : ::Sebas::Platform::Config::Config
  yaml = <<-YAML
    channels:
      email:
        accounts:
          - id: test-acc
            platform: 127.0.0.1
            receive: imap-idle
            smtp: { port: 2525, tls: none }
            credentials: { user: me@example.com, password: p }
    agents:
      main: { model: fake/chat }
    bindings:
      - { channel: email, account: test-acc, peer: "*", agent: main }
    YAML
  ::Sebas::Platform::Config::Loader.from_content(yaml)
end

def gw_smtp_account : ::Sebas::Platform::Config::EmailAccount
  ::Sebas::Platform::Config::EmailAccount.from_yaml(<<-YAML
    id: test-acc
    platform: 127.0.0.1
    receive: imap-idle
    credentials: { user: me@example.com, password: p }
    YAML
  )
end
