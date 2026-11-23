require "./providers"

# CrystalLLMProvider：基于 ShiningRay/crystal-llm（ruby_llm 的 Crystal 移植）的
# Provider 适配。每个实例用 CrystalLLM::Context 复制独立配置，避免多 agent 之间
# API key / base_url 互相污染；LLM 异常统一转 Completion.error，不炸进程
# （Providers::Completion 的 typed rescue 纪律，design.md §4.1）。
module Sebas
  module Providers
    class CrystalLLMProvider < Provider
      def initialize(@model : String, @provider : String, @api_key : String,
                     @api_base : String? = nil)
        super(@model)
      end

      def complete(messages : Array(Message)) : Completion
        context = CrystalLLM::Context.create(CrystalLLM.config) do |config|
          apply_provider_config(config)
        end

        chat = context.chat(model: @model, provider: @provider, assume_model_exists: true)
        messages.each do |message|
          chat.add_message(CrystalLLM::Message.new(role: message.role, content: message.content))
        end
        response = chat.complete
        text = response.is_a?(CrystalLLM::Message) ? response.content : nil
        Completion.new(text.try(&.to_s) || "", nil)
      rescue ex : ::Exception
        Log.warn { "crystal_llm completion failed: #{ex.message}" }
        Completion.error("crystal_llm request failed: #{ex.message}")
      end

      private def apply_provider_config(config : CrystalLLM::Configuration) : Nil
        raise ::Exception.new("missing api key for provider '#{@provider}'") if @api_key.empty?

        case @provider
        when "openai"
          config.openai_api_key = @api_key
          config.openai_api_base = @api_base if @api_base
        when "anthropic"
          config.anthropic_api_key = @api_key
          config.anthropic_api_base = @api_base if @api_base
        when "deepseek"
          config.deepseek_api_key = @api_key
          config.deepseek_api_base = @api_base if @api_base
        when "openrouter"
          config.openrouter_api_key = @api_key
          config.openrouter_api_base = @api_base if @api_base
        else
          raise ::Exception.new("unsupported crystal_llm provider '#{@provider}'")
        end
      end
    end
  end
end
