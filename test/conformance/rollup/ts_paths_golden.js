'use strict';

function Button(props) {
  return "<button>" + props.label + "</button>";
}

const view = React.createElement(Button, { label: "dark" ,} );
const rendered = view;

exports.rendered = rendered;
