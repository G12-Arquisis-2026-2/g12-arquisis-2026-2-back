# Ejemplos oficiales del protocolo v3

Copiados sin cambios desde https://github.com/iic2173/energyshark-contracts, tag `v3.0.2`
(commit `62f6cf4`), carpeta `examples/amqp/`. Solo están los tipos que el connector recibe:
los de la cola `city.{CODE}` (central, wallet y otras ciudades) y los de `market.{CODE}`.

- `valid/*.json`: mensajes completos que deben aceptarse.
- `invalid/*.json`: mutaciones de un ejemplo válido (`base`, `set`, `unset`) con el motivo
  esperado en `expect.keyword`.

Los usa `test/contract_examples_test.rb`. Para actualizarlos, volver a copiarlos desde el tag
nuevo y cambiar el nombre de esta carpeta.
