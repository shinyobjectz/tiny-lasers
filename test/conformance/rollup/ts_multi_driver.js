// Layer-3 driver: a multi-file TypeScript project bundled by rollup with a SUCRASE transform plugin.
// Proves .ts/.tsx resolution + per-module type-stripping + cross-module treeshaking + scope hoisting.
var tsFiles = {
  "entry.ts": [
    'import { greet, Farewell } from "./lib";',
    'import { VERSION } from "./meta";',
    'interface Person { name: string }',
    'const who: Person = { name: "world" };',
    'export const msg: string = greet(who.name) + " " + new Farewell().say(who.name) + VERSION;',
    'console.log(msg);'
  ].join("\n"),
  "lib.ts": [
    'import { upper, PUNCT } from "./util";',
    'export function greet(n: string): string { return "hi " + upper(n) + PUNCT; }',
    'export class Farewell { say(n: string): string { return "bye " + n; } }',
    'export function neverUsed(): number { return 42; }'  // dead → treeshaken
  ].join("\n"),
  "util.ts": [
    'export const upper = (s: string): string => s.toUpperCase();',
    'export const PUNCT: string = "!";',
    'export const enum Unused { A, B }'  // const enum, dead
  ].join("\n"),
  "meta.ts": [
    'export const VERSION: string = "@v1";',
    'type Dead = string | number;',            // type-only, erased
    'export function alsoDead(): Dead { return 0; }'  // dead → treeshaken
  ].join("\n")
};
function resolveTs(id) {
  if (id in tsFiles) return id;
  var withExt = id.replace(/^\.\//, "") + ".ts";
  if (withExt in tsFiles) return withExt;
  return null;
}
var tsPlugin = {
  name: "ts",
  resolveId: function(id) { return resolveTs(id); },
  load: function(id) { return id in tsFiles ? tsFiles[id] : null; },
  transform: function(code, id) {
    if (/\.tsx?$/.test(id)) {
      return { code: SUCRASE.transform(code, { transforms: ["typescript"] }).code, map: null };
    }
    return null;
  }
};
rollup.rollup({ input: "entry.ts", plugins: [tsPlugin], treeshake: true })
  .then(function(b) { return b.generate({ format: "cjs" }); })
  .then(function(r) { console.log("TSBUNDLE_OK[" + r.output[0].code + "]"); })
  .catch(function(e) { console.log("TSBUNDLE_ERR " + (e && e.stack ? e.stack : e)); });
