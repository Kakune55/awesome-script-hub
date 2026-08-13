(function () {
  "use strict";

  const listeners = new Set();

  // Hash 路由无需服务端重写规则，适合直接部署到静态托管平台。
  function current() {
    const raw = window.location.hash.replace(/^#/, "") || "/";
    const path = raw.startsWith("/") ? raw : `/${raw}`;

    if (path === "/") return { name: "home", params: {} };

    const scriptMatch = path.match(/^\/script\/([a-z0-9-]+)\/?$/i);
    if (scriptMatch) {
      return {
        name: "script",
        params: { id: decodeURIComponent(scriptMatch[1]) }
      };
    }

    return { name: "not-found", params: {} };
  }

  function notify() {
    const route = current();
    listeners.forEach((listener) => listener(route));
    window.scrollTo({ top: 0, behavior: "auto" });
  }

  window.addEventListener("hashchange", notify);

  window.Router = {
    current,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    start() {
      notify();
    },
    go(path) {
      window.location.hash = path;
    }
  };
})();
