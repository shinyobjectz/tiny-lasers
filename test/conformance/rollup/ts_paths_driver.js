var files = {
  "src/app/main.tsx": [
    'import { Button } from "@app/ui/Button";',
    'import type { Theme } from "@app/types";',   // .d.ts, type-only → erased
    'const theme: Theme = { dark: true };',
    'const view = <Button label={theme.dark ? "dark" : "light"} />;',
    'export const rendered: string = view;'
  ].join("\n"),
  "src/app/ui/Button.tsx": [
    'export function Button(props: { label: string }): string {',
    '  return "<button>" + props.label + "</button>";',
    '}'
  ].join("\n"),
  "src/app/types.d.ts": [
    'export interface Theme { dark: boolean }'
  ].join("\n")
};
// tsconfig-style resolution: baseUrl "src", paths "@app/*" -> "app/*", try .tsx/.ts/.d.ts extensions.
var baseUrl = "src";
var paths = { "@app/": "app/" };
function resolveModule(id, importer) {
  var base = id;
  for (var k in paths) { if (id.indexOf(k) === 0) { base = baseUrl + "/" + paths[k] + id.slice(k.length); break; } }
  if (base === id && id.charAt(0) === ".") {
    var dir = importer ? importer.slice(0, importer.lastIndexOf("/")) : baseUrl;
    base = dir + "/" + id.replace(/^\.\//, "");
  }
  var exts = ["", ".tsx", ".ts", ".d.ts"];
  for (var i = 0; i < exts.length; i++) { if ((base + exts[i]) in files) return base + exts[i]; }
  return null;
}
var plugin = {
  name: "tsconfig-paths",
  resolveId: function(id, importer) { return resolveModule(id, importer); },
  load: function(id) { return id in files ? files[id] : null; },
  transform: function(code, id) {
    if (/\.tsx?$/.test(id) || /\.d\.ts$/.test(id)) {
      return { code: SUCRASE.transform(code, { transforms: ["typescript", "jsx"], jsxRuntime: "classic", production: true }).code, map: null };
    }
    return null;
  }
};
rollup.rollup({ input: "src/app/main.tsx", plugins: [plugin], treeshake: true })
  .then(function(b) { return b.generate({ format: "cjs" }); })
  .then(function(r) { console.log("TSPATHS_OK[" + r.output[0].code + "]"); })
  .catch(function(e) { console.log("TSPATHS_ERR " + (e && e.stack ? e.stack : e)); });
