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

# 随机端口：`port: 0` 让内核分配空闲端口，避开默认 18790/18791。开发机常驻
# 一个 `sebas gateway` 时，spec 抢默认端口会整片报 Address already in use；
# 同一台机上并行跑多个 spec 进程也同理。实际端口在 `#run` 之后从
# `gateway.http.port` / `gateway.ipc.port` 取（listen 会把分配结果写回）。
# 注意 Crystal heredoc 不含结尾换行，拼接时须显式补 "\n"。
def gw_random_port_yaml : String
  <<-YAML
    gateway:
      http: { port: 0 }
      ipc: { port: 0 }
    YAML
end

def gw_test_config : ::Sebas::Platform::Config::Config
  yaml = gw_random_port_yaml + "\n" + <<-YAML
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
