// Stage 1 (BUILD): rollup bundles a REAL multi-component Preact app (entry + 5 component modules, `preact`
// external) into one CJS module. Appended after rollup_bundle.cjs (reuses its `rollup` binding). Prints
// APP_BUILD_OK[<bundled cjs>]. This is the build lane on real app code (not synthetic exports).
var appFiles = {
  "entry": [
    "import { App } from './App.js';",
    "export { App };"
  ].join("\n"),
  "./App.js": [
    "import { h, Fragment } from 'preact';",
    "import { Header } from './Header.js';",
    "import { CardList } from './CardList.js';",
    "import { Footer } from './Footer.js';",
    "export function App(props) {",
    "  return h('div', { id: 'app' }, [",
    "    h(Header, { title: props.title }),",
    "    props.intro ? h('p', { class: 'intro' }, props.intro) : null,",
    "    h(CardList, { cards: props.cards }),",
    "    h(Footer, { year: props.year })",
    "  ]);",
    "}"
  ].join("\n"),
  "./Header.js": [
    "import { h } from 'preact';",
    "export function Header(props) {",
    "  return h('header', null, [",
    "    h('h1', null, props.title),",
    "    h('nav', null, ['home', 'about', 'contact'].map(function (l) { return h('a', { href: '/' + l }, l); }))",
    "  ]);",
    "}"
  ].join("\n"),
  "./CardList.js": [
    "import { h } from 'preact';",
    "import { Card } from './Card.js';",
    "export function CardList(props) {",
    "  return h('ul', { class: 'cards' }, props.cards.map(function (c, i) {",
    "    return h(Card, { key: i, title: c.title, tag: c.tag, featured: i === 0 });",
    "  }));",
    "}"
  ].join("\n"),
  "./Card.js": [
    "import { h } from 'preact';",
    "export function Card(props) {",
    "  return h('li', { class: props.featured ? 'card featured' : 'card' }, [",
    "    h('strong', null, props.title),",
    "    props.tag ? h('span', { class: 'tag' }, props.tag) : null",
    "  ]);",
    "}"
  ].join("\n"),
  "./Footer.js": [
    "import { h } from 'preact';",
    "export function Footer(props) { return h('footer', null, '(c) ' + props.year + ' — built + SSR on F2'); }"
  ].join("\n")
};

var appVirt = {
  name: "app",
  resolveId: function (id) {
    if (id in appFiles) return id;
    if (id && id.indexOf("./") === 0 && id in appFiles) return id;
    return id === "preact" ? false : null;
  },
  load: function (id) { return id in appFiles ? appFiles[id] : null; }
};

rollup.rollup({ input: "entry", plugins: [appVirt], external: ["preact"], treeshake: true })
  .then(function (b) { return b.generate({ format: "cjs", exports: "named" }); })
  .then(function (g) { print("APP_BUILD_OK[" + g.output[0].code + "]"); })
  .catch(function (e) { print("APP_BUILD_ERR " + (e && e.stack ? e.stack : e)); });
