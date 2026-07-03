function Card(props) {
  return React.createElement('div', { className: "c",}, React.createElement('h1', null, props.title), React.createElement('span', null, 1 + 2));
}
