// A tiny, dependency-free Preact vnode -> string renderer for `node --test`.
//
// Why not preact-render-to-string / jsdom? The repo deliberately runs its frontend tests with no
// package.json, no node_modules, and no DOM toolchain (see tests/frontend/logic.test.mjs). The
// dashboard components (components.mjs) make that affordable: they are pure functional or simple
// class components with NO hooks, and their only browser work (Chart.js, refs) lives in
// componentDidMount — never in render(). So a static walk of the vnode tree reproduces exactly what
// the browser paints on first mount, with zero dependencies.
//
// This intentionally does NOT run effects, refs, or event handlers, and does not escape text — it
// is a render *probe* for asserting structure/content in tests, not a production SSR engine.

// Props that are never serialized as HTML attributes.
const SKIP_ATTRS = new Set(["children", "key", "ref"]);

function attrs(props) {
  let out = "";
  for (const name of Object.keys(props)) {
    if (SKIP_ATTRS.has(name)) continue;
    const v = props[name];
    if (v == null || v === false || typeof v === "function") continue; // handlers/empty -> dropped
    if (name === "style" && typeof v === "object") {
      const css = Object.entries(v)
        .map(([p, val]) => `${p}:${val}`)
        .join(";");
      out += ` style="${css}"`;
      continue;
    }
    if (typeof v === "object") continue; // other object-valued props have no string form
    if (v === true) {
      out += ` ${name}`;
      continue;
    }
    out += ` ${name}="${String(v)}"`;
  }
  return out;
}

export function renderToString(vnode) {
  if (vnode == null || vnode === false || vnode === true) return "";
  if (typeof vnode === "string" || typeof vnode === "number" || typeof vnode === "bigint") {
    return String(vnode);
  }
  if (Array.isArray(vnode)) return vnode.map(renderToString).join("");

  const { type, props = {} } = vnode;
  if (type == null) return "";

  if (typeof type === "function") {
    // A class component carries its own render() on the prototype; functional and arrow
    // components do not (arrows have no prototype at all). Preact's Fragment is a plain function
    // that returns props.children, so it falls through the functional branch correctly.
    if (type.prototype && typeof type.prototype.render === "function") {
      const inst = new type(props);
      inst.props = props;
      if (inst.state == null) inst.state = {};
      return renderToString(inst.render(inst.props, inst.state, inst.context));
    }
    return renderToString(type(props));
  }

  return `<${type}${attrs(props)}>${renderToString(props.children)}</${type}>`;
}

// Render a component to a string given its props, e.g. render(App, { state, ui, ...handlers }).
export function render(Component, props = {}) {
  return renderToString({ type: Component, props });
}
