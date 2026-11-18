# 渠道公共件（M0-WP4）：markdown 转换器【A8 直接搬：纯函数、与账号无关】
# email 渠道 markdown 原生；此转换器供需要纯文本的渠道/出站降级使用
module Sebas
  module Channels
    module Common
      extend self

      # markdown → 纯文本：图片留 alt+URL、链接留 URL、剥强调/代码围栏标记、清单保留符号
      def markdown_to_text(md : String) : String
        md.lines.map { |line| inline_to_text(line) }.join("\n")
      end

      private def inline_to_text(line : String) : String
        line = line.gsub(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/) do |_, match|
          match[1].empty? ? match[2].to_s : "#{match[1]} (#{match[2]})"
        end
        line = line.gsub(/\[([^\]]+)\]\(([^)\s]+)[^)]*\)/) { |_, match| "#{match[1]} (#{match[2]})" }
        line = line.gsub(/(?:\*\*|__)(.+?)(?:\*\*|__)/) { |_, match| match[1] }
        line = line.gsub(/(?:\*|_)([^*_]+?)(?:\*|_)/) { |_, match| match[1] }
        line = line.gsub(/`{1,3}([^`]*)`{1,3}/) { |_, match| match[1] }
        line.gsub(/^\#{1,6}\s+/, "")
      end
    end
  end
end
