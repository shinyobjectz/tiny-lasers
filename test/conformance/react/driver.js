// React 18 SSR probe for F2 — exercises the same surface as the preact gate test:
// function components + props/children, useState/useReducer/useMemo/useContext, createContext+Provider,
// memo, style objects, boolean/aria/data attrs, dangerouslySetInnerHTML, keys, mixed falsy children.
const React = require('react');
const { renderToString } = require('react-dom/server');
const e = React.createElement;

const Theme = React.createContext('light');

function Badge({ label, count }) {
  const [n] = React.useState(count);
  const doubled = React.useMemo(() => n * 2, [n]);
  const theme = React.useContext(Theme);
  return e('span', { className: 'badge ' + theme, 'data-n': doubled, 'aria-hidden': false }, label, ':', doubled);
}

const MemoBadge = React.memo(Badge);

function List({ items }) {
  const [state] = React.useReducer((s) => s, { open: true });
  return e('ul', { style: { marginTop: '4px', backgroundColor: 'rgb(1,2,3)' } },
    items.map((it, i) => e('li', { key: it }, it, i === 0 ? e(MemoBadge, { label: 'top', count: 3 }) : null)),
    state.open ? e('li', { hidden: true }, 'open') : false,
    null, undefined, 0, '');
}

function App() {
  return e(Theme.Provider, { value: 'dark' },
    e('div', { id: 'root' },
      e('h1', null, 'F2 React'),
      e(List, { items: ['a', 'b'] }),
      e('p', { dangerouslySetInnerHTML: { __html: '<b>raw</b>' } })));
}

print('REACT_OK[' + renderToString(e(App)) + ']');
