# Ejemplos oficiales del protocolo v3.0.2 (los mismos que usa el connector en sus contract tests).
module ContractExamples
  DIR = Rails.root.join("connector/test/fixtures/contracts-v3.0.2/amqp")

  def contract_example(type, name)
    JSON.parse(DIR.join(type, "valid", "#{name}.json").read)
  end
end
