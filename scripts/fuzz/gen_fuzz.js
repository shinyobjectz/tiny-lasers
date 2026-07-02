// F2 differential fuzzer — GENERATOR. Emits a combinatorial corpus of small JS expressions across construct
// families, each paired with the oracle (node/V8) output. Deterministic (no RNG) → reproducible. The Elixir
// side runs each `print(<expr>)` through F2 (Walk+Lower) and diffs against the oracle. Output: TSV
// `<expr>\t<json-encoded-output-or-THROW>` per line. (QuickJS can replace the oracle by swapping the eval.)
const lines = [];
function emit(expr) {
  let out;
  try {
    // eval in a fresh-ish scope; the expr must be a single expression producing a printable value.
    out = String(eval(expr));
  } catch (e) {
    // a SyntaxError expr (e.g. `-1 ** 2`, which needs parens) can't be embedded in the batched F2 program —
    // it would break the whole program's parse. Skip it; the oracle catches it per-expr but F2 parses en masse.
    if (e instanceof SyntaxError) return;
    out = "THROW:" + (e && e.constructor ? e.constructor.name : "Error");
  }
  lines.push(expr + "\t" + JSON.stringify(out));
}

const nums = ["0", "1", "-1", "2", "3", "7", "10", "-5", "0.5", "-0.25", "100", "255", "1.5", "2.5", "-3.5", "1e3", "0.1", "3.14"];
const ops = ["+", "-", "*", "/", "%", "**", "&", "|", "^", "<<", ">>", ">>>", "<", ">", "<=", ">=", "===", "!=="];
// numeric operators
for (const a of nums) for (const op of ops) for (const b of ["0", "1", "2", "3", "-1", "0.5", "10"]) emit(`${a} ${op} ${b}`);

const strs = ['"hello"', '"AbC"', '""', '"  pad  "', '"a,b,c"', '"12.5"', '"café"', '"line1\\nline2"'];
const strM = [
  (s) => `${s}.length`, (s) => `${s}.toUpperCase()`, (s) => `${s}.toLowerCase()`, (s) => `${s}.trim()`,
  (s) => `${s}.slice(1)`, (s) => `${s}.slice(1, 3)`, (s) => `${s}.slice(-2)`, (s) => `${s}.substring(1, 3)`,
  (s) => `${s}.substr(1, 2)`, (s) => `${s}.charAt(1)`, (s) => `${s}.charCodeAt(0)`, (s) => `${s}.codePointAt(0)`,
  (s) => `${s}.indexOf("a")`, (s) => `${s}.lastIndexOf("a")`, (s) => `${s}.includes("l")`, (s) => `${s}.startsWith("h")`,
  (s) => `${s}.endsWith("o")`, (s) => `${s}.repeat(2)`, (s) => `${s}.padStart(8, "*")`, (s) => `${s}.padEnd(8, "*")`,
  (s) => `${s}.replace("a", "X")`, (s) => `${s}.replaceAll("a", "X")`, (s) => `${s}.split(",").join("|")`,
  (s) => `${s}.at(-1)`, (s) => `${s}.concat("!")`, (s) => `JSON.stringify(${s})`, (s) => `[...${s}].length`,
];
for (const s of strs) for (const f of strM) emit(f(s));

const arrs = ["[1,2,3]", "[3,1,2]", "[]", "[5,5,5]", "[1,2,3,4,5]", '["a","b","c"]', "[1.5, 2.5, -3]", "[true, false, 0, 1]"];
const arrM = [
  (a) => `${a}.length`, (a) => `${a}.join("-")`, (a) => `${a}.slice(1).join(",")`, (a) => `${a}.slice(-2).join(",")`,
  (a) => `${a}.concat([9]).join(",")`, (a) => `${a}.indexOf(2)`, (a) => `${a}.includes(2)`, (a) => `${a}.reverse().join(",")`,
  (a) => `${a}.map(function(x){return x*2;}).join(",")`, (a) => `${a}.filter(function(x){return x>1;}).join(",")`,
  (a) => `${a}.reduce(function(s,x){return s+x;}, 0)`, (a) => `${a}.find(function(x){return x>1;})`,
  (a) => `${a}.findIndex(function(x){return x>1;})`, (a) => `${a}.some(function(x){return x>2;})`,
  (a) => `${a}.every(function(x){return x>0;})`, (a) => `${a}.sort().join(",")`, (a) => `${a}.flat().join(",")`,
  (a) => `${a}.at(-1)`, (a) => `${a}.fill(0).join(",")`, (a) => `Array.from(${a}).join(",")`,
  (a) => `${a}.flatMap(function(x){return [x,x];}).join(",")`, (a) => `${a}.lastIndexOf(5)`,
];
for (const a of arrs) for (const f of arrM) emit(f(a));

const coerce = ["undefined", "null", "true", "false", "0", "1", "-1", "NaN", "Infinity", '"5"', '"x"', "[]", "[1]", "[1,2]", "{}", '"3.14"'];
for (const v of coerce) {
  emit(`String(${v})`); emit(`Number(${v})`); emit(`Boolean(${v})`); emit(`+${v}`); emit(`!${v}`);
  emit(`${v} + ""`); emit(`"" + ${v}`); emit(`typeof ${v}`); emit(`${v} == 0`); emit(`${v} === undefined`);
  emit(`parseInt(${v})`); emit(`parseFloat(${v})`); emit(`JSON.stringify(${v})`); emit(`isNaN(${v})`);
}

const mathA = ["floor", "ceil", "round", "trunc", "abs", "sign", "sqrt", "cbrt", "log2", "log10"];
for (const m of mathA) for (const n of ["0", "1.5", "-1.5", "2.7", "-2.3", "9", "0.5", "16"]) emit(`Math.${m}(${n})`);
for (const n of ["2,3", "10,3", "-1,5", "0,0"]) { emit(`Math.max(${n})`); emit(`Math.min(${n})`); emit(`Math.pow(${n})`); }

require("fs").writeFileSync(process.argv[2], lines.join("\n"));
console.log("emitted " + lines.length + " fuzz cases");
