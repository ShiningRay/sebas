require "sqlite3"
require "uri"

dir = Path[ENV["TEMP"], "sebas-uriprobe"]
Dir.mkdir(dir) unless Dir.exists?(dir)
p1 = (dir / "opaque.db").to_s
p2 = (dir / "auth.db").to_s

uri1 = "sqlite3:#{p1}?max_pool_size=1"
puts "URI1=#{uri1}"
begin
  d1 = DB.open(uri1)
  d1.exec("CREATE TABLE IF NOT EXISTS t (v TEXT)")
  puts "OPAQUE_OK #{d1.scalar("PRAGMA journal_mode")}"
  d1.close
rescue ex
  puts "OPAQUE_FAIL #{ex.class} #{ex.message}"
end

uri2 = "sqlite3://#{p2}?max_pool_size=1"
puts "URI2=#{uri2}"
begin
  d2 = DB.open(uri2)
  d2.exec("CREATE TABLE IF NOT EXISTS t (v TEXT)")
  puts "AUTH_OK #{File.exists?(p2)}"
  d2.close
rescue ex
  puts "AUTH_FAIL #{ex.class} #{ex.message}"
end
puts "EXISTS1=#{File.exists?(p1)} EXISTS2=#{File.exists?(p2)}"
