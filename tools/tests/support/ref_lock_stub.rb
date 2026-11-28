# frozen_string_literal: true

# 跨机 ref 锁（#306）的假 gh 路由：git commits/refs 端点的最小实现。
#
# 各域的假 runner（FakeGhStore / 匿名 CommandRunner 替身）在自己的入口
# 先调 ref_lock_read / ref_lock_write，命中即用，未命中走原逻辑。语义与
# 真服务端一致：同名 ref 并发 POST 恰一个成功，另一个 422 already exists；
# 全程持 Mutex，支持真双线程争锁。dry-run 的跳过由产品代码负责（gateway
# .dry_run?），这里只处理 dry_run: false 的替身。
module RefLockStub
  GIT_COMMITS_POST = %r{\Arepos/[^/]+/[^/]+/git/commits\z}
  GIT_COMMITS_GET = %r{\Arepos/[^/]+/[^/]+/git/commits/([0-9a-f]+)\z}
  GIT_REFS_POST = %r{\Arepos/[^/]+/[^/]+/git/refs\z}
  GIT_REFS_GET = %r{\Arepos/[^/]+/[^/]+/git/matching-refs/\S+\z}
  GIT_REFS_DELETE = %r{\Arepos/[^/]+/[^/]+/git/refs/(\S+)\z}

  def init_ref_lock_stub
    @ref_lock_mutex ||= Mutex.new
    @ref_lock_refs ||= {}     # ref 名 => commit sha
    @ref_lock_commits ||= {}  # sha => message（锁凭据 JSON）
    @ref_lock_commit_seq ||= 0
  end

  # json! 入口的读路由：命中返回 Ruby 对象（Array/Hash），未命中返回 nil。
  def ref_lock_read(argv)
    init_ref_lock_stub
    @ref_lock_mutex.synchronize do
      return nil unless argv[0] == "gh" && argv[1] == "api"

      if argv[2].to_s.match?(GIT_REFS_GET)
        prefix = argv[2].split("matching-refs/").last.gsub("%2F", "/")
        return @ref_lock_refs.select { |name, _| name.start_with?(prefix) }
                             .map { |name, sha| {"ref" => name, "object" => {"sha" => sha}} }
      end
      if (m = argv[2].to_s.match(GIT_COMMITS_GET))
        return {"message" => @ref_lock_commits[m[1]] || ""}
      end
      nil
    end
  end

  # run! 入口的写路由：命中返回 JSON 字符串，未命中返回 nil。
  def ref_lock_write(argv)
    init_ref_lock_stub
    @ref_lock_mutex.synchronize do
      return nil unless argv[0] == "gh" && argv[1] == "api"

      if argv[2].to_s.match?(GIT_COMMITS_POST)
        @ref_lock_commit_seq += 1
        sha = format("%040x", @ref_lock_commit_seq)
        @ref_lock_commits[sha] = argv.find { |arg| arg.to_s.start_with?("message=") }
                                     .to_s.sub(/\Amessage=/, "")
        return JSON.generate({"sha" => sha})
      end
      if argv[2].to_s.match?(GIT_REFS_POST)
        ref = argv.find { |arg| arg.to_s.start_with?("ref=") }.to_s.sub(/\Aref=/, "")
        if @ref_lock_refs.key?(ref)
          raise SebasAgents::CommandError.new(
            "gh: HTTP 422: Unprocessable Entity: \"Reference already exists\" (#{ref})",
            command: argv
          )
        end
        @ref_lock_refs[ref] = argv.find { |arg| arg.to_s.start_with?("sha=") }.to_s.sub(/\Asha=/, "")
        return JSON.generate({"ref" => ref})
      end
      if argv[2] == "-X" && argv[3] == "DELETE" && (m = argv[4].to_s.match(GIT_REFS_DELETE))
        @ref_lock_refs.delete(m[1].gsub("%2F", "/"))
        return "{}"
      end
      nil
    end
  end
end
