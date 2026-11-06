// Valida con el validador oficial del curso los mensajes que emite nuestro código.
//
// Uso (desde esta carpeta, con el paquete del curso instalado aquí):
//   npm install --no-save "github:iic2173/energyshark-contracts#v3.0.2"
//   node validate-contracts.mjs <carpeta> [--types ack,nack,bid,...]
//
// <carpeta> la llenan connector/test/emitted_messages_test.rb y
// test/contracts/emitted_outbox_messages_test.rb (variable EMITTED_MESSAGES_DIR), con un archivo
// <type>--<routing key>--<caso>.json por mensaje. Cada uno se valida contra
// SCHEMA_BASE + "amqp/<type>.schema.json", tal como dice el README del curso.
// --types: tipos que tienen que aparecer al menos una vez (si falta uno, el generador no escribió).
// Termina con código 1 si algún mensaje no valida, si falta un tipo o si la carpeta está vacía.

import { createValidator, SCHEMA_BASE } from '@iic2173/energyshark-contracts/validator';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const typesFlag = args.indexOf('--types');
const requiredTypes = typesFlag >= 0 ? args.splice(typesFlag, 2)[1].split(',').filter(Boolean) : [];
const dir = args[0] ?? process.env.EMITTED_MESSAGES_DIR;

if (!dir || !fs.existsSync(dir)) {
  console.error(`No existe la carpeta de mensajes: ${dir ?? '(sin argumento ni EMITTED_MESSAGES_DIR)'}`);
  process.exit(1);
}

const files = fs.readdirSync(dir).filter((name) => name.endsWith('.json')).sort();
if (files.length === 0) {
  console.error(`No hay mensajes en ${dir}: los tests que los generan no escribieron nada.`);
  process.exit(1);
}

const ajv = createValidator();
const results = [];

for (const file of files) {
  const [fileType, routingKey = '?', label = ''] = file.replace(/\.json$/, '').split('--');
  const problems = [];
  let message;
  try {
    message = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
  } catch (error) {
    problems.push(`no es JSON: ${error.message}`);
  }

  const type = message?.type;
  if (message && type !== fileType) problems.push(`el archivo dice ${fileType} pero type es ${JSON.stringify(type)}`);

  const validate = typeof type === 'string' ? ajv.getSchema(`${SCHEMA_BASE}amqp/${type}.schema.json`) : undefined;
  if (message && !validate) problems.push(`no hay schema para type ${JSON.stringify(type)}`);
  if (validate && !validate(message)) {
    for (const e of validate.errors) {
      problems.push(`${e.instancePath || '/'} ${e.keyword}: ${e.message} ${JSON.stringify(e.params)} (${e.schemaPath})`);
    }
  }
  // regla que un schema no expresa (README del curso): idpk distinto de msgId
  if (message && message.idpk === message.msgId) problems.push('idpk igual a msgId');

  results.push({ file, type: type ?? fileType, routingKey, label, problems });
}

const missing = requiredTypes.filter((type) => !results.some((r) => r.type === type));

console.log(`Validador oficial: SCHEMA_BASE ${SCHEMA_BASE}`);
console.log('| type | routing key | caso | resultado |');
console.log('| --- | --- | --- | --- |');
for (const r of results) {
  console.log(`| ${r.type} | ${r.routingKey} | ${r.label} | ${r.problems.length ? 'ERROR' : 'válido'} |`);
}
for (const r of results.filter((x) => x.problems.length)) {
  console.error(`\n${r.file} no cumple el contrato:`);
  for (const p of r.problems) console.error(`  - ${p}`);
}
if (missing.length) console.error(`\nFaltan mensajes de tipo: ${missing.join(', ')}`);

const failed = results.filter((r) => r.problems.length).length;
console.log(`\n${results.length - failed}/${results.length} mensajes válidos`);
if (failed || missing.length) process.exit(1);
