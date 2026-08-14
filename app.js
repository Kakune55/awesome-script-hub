(function () {
  "use strict";

  const app = document.querySelector("#app");
  const toast = document.querySelector("#toast");
  const themeToggle = document.querySelector("#theme-toggle");
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");
  const state = { scripts: [], documents: new Map(), query: "", os: "all", tag: "all" };

  const dangerLabels = {
    safe: "低风险",
    warning: "需要谨慎",
    danger: "高风险"
  };

  const osIconSlugs = {
    "AlmaLinux": "almalinux",
    "Alpine Linux": "alpinelinux",
    "Arch Linux": "archlinux",
    "CentOS": "centos",
    "Debian": "debian",
    "Debian 13": "debian",
    "Fedora": "fedora",
    "Gentoo": "gentoo",
    "Linux": "linux",
    "openSUSE": "opensuse",
    "RHEL": "redhat",
    "Rocky Linux": "rockylinux",
    "Ubuntu": "ubuntu"
  };

  function escapeHTML(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "'": "&#39;",
      '"': "&quot;"
    })[character]);
  }

  function absoluteURL(path) {
    return new URL(path, document.baseURI).href;
  }

  function savedTheme() {
    try {
      const value = localStorage.getItem("ash-theme");
      return value === "light" || value === "dark" ? value : null;
    } catch (error) {
      return null;
    }
  }

  function applyTheme(preference) {
    const theme = preference || (systemTheme.matches ? "dark" : "light");
    if (preference) document.documentElement.dataset.theme = preference;
    else delete document.documentElement.dataset.theme;

    const lightHighlight = document.querySelector("#hljs-light");
    const darkHighlight = document.querySelector("#hljs-dark");
    lightHighlight.media = preference ? (theme === "light" ? "all" : "not all") : "(prefers-color-scheme: light)";
    darkHighlight.media = preference ? (theme === "dark" ? "all" : "not all") : "(prefers-color-scheme: dark)";

    document.querySelector('meta[name="theme-color"]').content = theme === "dark" ? "#17191c" : "#f5f5f5";
    themeToggle.querySelector("span").textContent = theme === "dark" ? "☀" : "☾";
    themeToggle.setAttribute("aria-label", `切换到${theme === "dark" ? "浅色" : "深色"}模式`);
    themeToggle.title = theme === "dark" ? "切换到浅色模式" : "切换到深色模式";
  }

  function initTheme() {
    applyTheme(savedTheme());
    themeToggle.addEventListener("click", () => {
      const current = document.documentElement.dataset.theme || (systemTheme.matches ? "dark" : "light");
      const next = current === "dark" ? "light" : "dark";
      try {
        localStorage.setItem("ash-theme", next);
      } catch (error) {
        // 隐私模式禁用存储时，本次切换仍然有效。
      }
      applyTheme(next);
    });
    systemTheme.addEventListener("change", () => {
      if (!savedTheme()) applyTheme(null);
    });
  }

  function showToast(message) {
    toast.textContent = message;
    toast.classList.add("is-visible");
    window.clearTimeout(showToast.timer);
    showToast.timer = window.setTimeout(() => toast.classList.remove("is-visible"), 1800);
  }

  async function copyText(text, button) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
      } else {
        const input = document.createElement("textarea");
        input.value = text;
        input.setAttribute("readonly", "");
        input.className = "clipboard-helper";
        document.body.appendChild(input);
        input.select();
        document.execCommand("copy");
        input.remove();
      }
      if (button) {
        const original = button.textContent;
        button.textContent = "已复制";
        window.setTimeout(() => { button.textContent = original; }, 1500);
      }
      showToast("已复制到剪贴板");
    } catch (error) {
      showToast("复制失败，请手动选择文本");
    }
  }

  function unique(field) {
    const values = state.scripts.flatMap((script) => Array.isArray(script[field]) ? script[field] : [script[field]]);
    return [...new Set(values)].filter(Boolean).sort((a, b) => a.localeCompare(b, "zh-CN"));
  }

  function scriptPaths(id, sourceName = "script.sh") {
    const directory = `scripts/${id}`;
    return { doc: `${directory}/README.md`, source: `${directory}/${sourceName}` };
  }

  // 源码类型与执行方式是前端能力，不属于内容索引。
  function sourceProfile(source) {
    const extension = source.split(".").pop().toLowerCase();
    const profiles = {
      sh: { language: "bash", executor: "bash" },
      bash: { language: "bash", executor: "bash" },
      py: { language: "python", executor: "python3" },
      go: { language: "go", executor: null },
      yaml: { language: "yaml", executor: null },
      yml: { language: "yaml", executor: null },
      json: { language: "json", executor: null },
      dockerfile: { language: "dockerfile", executor: null }
    };
    return profiles[extension] || { language: "plaintext", executor: null };
  }

  function osPreview(operatingSystems) {
    const visible = operatingSystems.slice(0, 4);
    const icons = visible.map((os) => {
      const slug = osIconSlugs[os];
      return slug ? `<img src="assets/os/${slug}.svg" alt="" width="18" height="18">` : "";
    }).join("");
    const remaining = operatingSystems.length - visible.length;

    return `
      <span class="os-preview" title="${escapeHTML(operatingSystems.join("、"))}" aria-label="支持 ${escapeHTML(operatingSystems.join("、"))}">
        <span class="os-icons" aria-hidden="true">${icons}${remaining > 0 ? `<span>+${remaining}</span>` : ""}</span>
      </span>`;
  }

  function osInformationList(operatingSystems) {
    return `<ul class="info-os-list">${operatingSystems.map((os) => {
      const slug = osIconSlugs[os];
      return `<li>${slug ? `<img src="assets/os/${slug}.svg" alt="" width="20" height="20">` : `<span class="os-placeholder" aria-hidden="true"></span>`}<span>${escapeHTML(os)}</span></li>`;
    }).join("")}</ul>`;
  }

  // 支持简单的 Hexo 风格 Front Matter；正文交给 markdown-it 处理。
  function parseFrontMatter(markdown) {
    const match = markdown.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/);
    if (!match) return { attributes: {}, body: markdown };

    const attributes = Object.create(null);
    match[1].split(/\r?\n/).forEach((line) => {
      const separator = line.indexOf(":");
      if (separator < 1) return;
      const key = line.slice(0, separator).trim();
      let value = line.slice(separator + 1).trim();
      if (value.startsWith("[") || value.startsWith("{")) {
        try {
          value = JSON.parse(value);
        } catch (error) {
          throw new Error(`Front Matter 字段 ${key} 不是有效的 JSON 数组或对象`);
        }
      }
      if (typeof value === "string" && ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
        value = value.slice(1, -1);
      }
      attributes[key] = value;
    });
    return { attributes, body: markdown.slice(match[0].length) };
  }

  function createScript(id, frontMatter) {
    const attributes = frontMatter.attributes;
    const paths = scriptPaths(id);
    const requiredStrings = ["title", "description", "updated"];
    const missing = requiredStrings.filter((field) => typeof attributes[field] !== "string" || !attributes[field].trim());
    if (missing.length) throw new Error(`${paths.doc} 缺少字段：${missing.join("、")}`);
    if (!Array.isArray(attributes.os) || !attributes.os.length) throw new Error(`${paths.doc} 的 os 必须是非空数组`);
    if (!Array.isArray(attributes.tags)) throw new Error(`${paths.doc} 的 tags 必须是数组`);

    const fileDefinitions = attributes.files || [{ name: attributes.source || "script.sh" }];
    if (!Array.isArray(fileDefinitions) || !fileDefinitions.length) throw new Error(`${paths.doc} 的 files 必须是非空数组`);
    const files = fileDefinitions.map((definition) => {
      const file = typeof definition === "string" ? { name: definition } : definition;
      if (!file || typeof file.name !== "string" || !/^[a-zA-Z0-9._-]+$/.test(file.name)) {
        throw new Error(`${paths.doc} 的文件名必须是当前目录内的文件名`);
      }
      const operatingSystems = file.os || attributes.os;
      if (!Array.isArray(operatingSystems) || !operatingSystems.length) {
        throw new Error(`${paths.doc} 中 ${file.name} 的 os 必须是非空数组`);
      }
      return {
        name: file.name,
        label: typeof file.label === "string" && file.label ? file.label : file.name,
        os: operatingSystems,
        path: scriptPaths(id, file.name).source
      };
    });

    return {
      id,
      title: attributes.title,
      description: attributes.description,
      os: attributes.os,
      tags: attributes.tags,
      files,
      updated: attributes.updated
    };
  }

  async function loadCatalog() {
    const response = await fetch("scripts.json", { cache: "no-cache" });
    if (!response.ok) throw new Error(`scripts.json: HTTP ${response.status}`);
    const ids = await response.json();
    if (!Array.isArray(ids)) throw new Error("scripts.json 必须是脚本 ID 数组");

    return Promise.all(ids.map(async (id) => {
      if (typeof id !== "string" || !/^[a-z0-9-]+$/.test(id)) throw new Error(`无效的脚本 ID：${id}`);
      const markdown = await fetchText(scriptPaths(id).doc);
      const frontMatter = parseFrontMatter(markdown);
      state.documents.set(id, frontMatter);
      return createScript(id, frontMatter);
    }));
  }

  function scriptCard(script) {
    return `
      <article class="script-row">
        <div class="script-main">
          <h3><a href="#/script/${encodeURIComponent(script.id)}">${escapeHTML(script.title)}</a></h3>
          <p>${escapeHTML(script.description)}</p>
          <div class="tag-row">
            ${script.tags.map((tag) => `<button class="tag" type="button" data-filter-tag="${escapeHTML(tag)}">${escapeHTML(tag)}</button>`).join("")}
          </div>
        </div>
        <div class="script-meta">
          ${osPreview(script.os)}
          <time datetime="${escapeHTML(script.updated)}">${escapeHTML(script.updated)}</time>
          <a class="detail-link" href="#/script/${encodeURIComponent(script.id)}">查看</a>
        </div>
      </article>`;
  }

  function filteredScripts() {
    const query = state.query.trim().toLocaleLowerCase("zh-CN");
    return state.scripts.filter((script) => {
      const haystack = [script.title, script.description, ...script.os, ...script.tags]
        .join(" ").toLocaleLowerCase("zh-CN");
      return (!query || haystack.includes(query))
        && (state.os === "all" || script.os.includes(state.os))
        && (state.tag === "all" || script.tags.includes(state.tag));
    });
  }

  function renderResults() {
    const results = filteredScripts();
    const target = document.querySelector("#script-results");
    const count = document.querySelector("#result-count");
    if (!target || !count) return;

    count.textContent = `${results.length} 个脚本`;
    target.innerHTML = results.length
      ? results.map(scriptCard).join("")
      : `<div class="empty-state"><span>⌕</span><h3>没有找到匹配脚本</h3><p>试试其他关键词或清除筛选条件。</p><button class="button secondary" id="reset-filters" type="button">清除筛选</button></div>`;
  }

  function renderHome() {
    document.title = "Awesome Script Hub — SRE 脚本库";
    const operatingSystems = unique("os");
    const tags = unique("tags");

    app.className = "page-shell";
    app.innerHTML = `
      <section class="library-section shell" id="all-scripts" aria-labelledby="library-title">
          <div class="page-heading">
            <div>
              <h1 id="library-title">脚本库</h1>
              <p>常用 SRE 脚本集合。执行前请阅读文档并检查源码。</p>
            </div>
            <span class="script-count" id="result-count">${state.scripts.length} 个脚本</span>
          </div>
          <div class="search-panel">
            <label class="search-box">
              <span aria-hidden="true">⌕</span>
              <span class="sr-only">搜索脚本</span>
              <input id="search-input" type="search" placeholder="搜索名称、简介或标签…" autocomplete="off">
            </label>
            <label class="select-box">
              <span class="sr-only">按分类筛选</span>
              <select id="os-filter">
                <option value="all">全部系统</option>
                ${operatingSystems.map((os) => `<option value="${escapeHTML(os)}">${escapeHTML(os)}</option>`).join("")}
              </select>
            </label>
          </div>
          <div class="tag-filters" aria-label="按标签筛选">
            <button class="filter-chip is-active" type="button" data-tag="all">全部</button>
            ${tags.map((tag) => `<button class="filter-chip" type="button" data-tag="${escapeHTML(tag)}">${escapeHTML(tag)}</button>`).join("")}
          </div>
          <div class="script-list" id="script-results">${state.scripts.map(scriptCard).join("")}</div>
      </section>`;

    bindHomeEvents();
  }

  function bindHomeEvents() {
    const search = document.querySelector("#search-input");
    const os = document.querySelector("#os-filter");

    search.addEventListener("input", (event) => {
      state.query = event.target.value;
      renderResults();
    });
    os.addEventListener("change", (event) => {
      state.os = event.target.value;
      renderResults();
    });

    app.onclick = (event) => {
      const tagButton = event.target.closest("[data-tag], [data-filter-tag]");
      if (tagButton) {
        state.tag = tagButton.dataset.tag || tagButton.dataset.filterTag;
        document.querySelectorAll("[data-tag]").forEach((button) => {
          button.classList.toggle("is-active", button.dataset.tag === state.tag);
        });
        document.querySelector("#all-scripts").scrollIntoView({ behavior: "smooth" });
        renderResults();
      }
      if (event.target.closest("#reset-filters")) {
        state.query = "";
        state.os = "all";
        state.tag = "all";
        renderHome();
        document.querySelector("#all-scripts").scrollIntoView();
      }
    };

    document.addEventListener("keydown", focusSearch);
  }

  function focusSearch(event) {
    if (event.key === "/" && !/input|textarea|select/i.test(document.activeElement.tagName)) {
      const search = document.querySelector("#search-input");
      if (search) {
        event.preventDefault();
        search.focus();
      }
    }
  }

  function markdownRenderer() {
    if (!window.markdownit) return null;
    const renderer = window.markdownit({
      html: false,
      linkify: true,
      typographer: true,
      highlight(code, language) {
        if (window.hljs && language && window.hljs.getLanguage(language)) {
          return window.hljs.highlight(code, { language }).value;
        }
        return escapeHTML(code);
      }
    });

    // 外部链接与当前页面隔离，Markdown 内不能注入任意 HTML。
    const defaultLinkOpen = renderer.renderer.rules.link_open || ((tokens, index, options, env, self) => self.renderToken(tokens, index, options));
    renderer.renderer.rules.link_open = (tokens, index, options, env, self) => {
      const href = tokens[index].attrGet("href") || "";
      if (/^https?:\/\//i.test(href)) {
        tokens[index].attrSet("target", "_blank");
        tokens[index].attrSet("rel", "noopener noreferrer");
      }
      return defaultLinkOpen(tokens, index, options, env, self);
    };
    return renderer;
  }

  function sourceLines(source, language) {
    // pre 会保留标签之间的空白，因此这里不能在相邻行节点间插入换行或缩进。
    return source.replace(/\n$/, "").split("\n").map((line, index) =>
      `<span class="source-line"><span class="line-number">${index + 1}</span><span class="line-code">${highlightLine(line, language)}</span></span>`
    ).join("");
  }

  function sourceLineCount(source) {
    return source.replace(/\n$/, "").split("\n").length;
  }

  function highlightLine(line, language) {
    if (!line) return " ";
    if (window.hljs && window.hljs.getLanguage(language)) {
      return window.hljs.highlight(line, { language, ignoreIllegals: true }).value;
    }
    return escapeHTML(line);
  }

  async function fetchText(path) {
    const response = await fetch(path);
    if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
    return response.text();
  }

  function renderIntroduction(script, frontMatter) {
    const panel = document.querySelector("#tab-panel");
    const danger = ["safe", "warning", "danger"].includes(frontMatter.attributes.danger)
      ? frontMatter.attributes.danger
      : null;
    const renderer = markdownRenderer();
    const docHTML = renderer
      ? renderer.render(frontMatter.body)
      : `<div class="dependency-error">Markdown 解析器加载失败，请检查网络后刷新页面。</div><pre>${escapeHTML(frontMatter.body)}</pre>`;
    const primaryFile = script.files[0];
    const profile = sourceProfile(primaryFile.path);
    const runCommand = script.files.length === 1 && profile.executor
      ? `curl -fsSL ${absoluteURL(primaryFile.path)} | ${profile.executor}`
      : null;
    const riskCard = danger && frontMatter.attributes.dangerMessage ? `
      <section class="info-card risk-card ${danger}">
        <h3><span class="risk-icon" aria-hidden="true">!</span>${dangerLabels[danger]}</h3>
        <p>${escapeHTML(frontMatter.attributes.dangerMessage)}</p>
      </section>` : "";

    panel.innerHTML = `
      <div class="overview-layout">
        <article class="markdown-body">${docHTML}</article>
        <aside class="info-sidebar" aria-label="脚本信息">
          ${riskCard}
          <section class="info-card">
            <h3>支持系统</h3>
            ${osInformationList(script.os)}
          </section>
          <section class="info-card facts-card">
            <h3>脚本信息</h3>
            <dl>
              <div><dt>更新时间</dt><dd>${escapeHTML(script.updated)}</dd></div>
              <div><dt>文件数量</dt><dd>${script.files.length}</dd></div>
              <div><dt>标签</dt><dd>${script.tags.length ? script.tags.map((tag) => `#${escapeHTML(tag)}`).join(" ") : "—"}</dd></div>
            </dl>
          </section>
          ${runCommand ? `
            <section class="info-card execute-card">
              <h3>一键执行</h3>
              <p>请先阅读说明和源码。</p>
              <div class="mini-command"><code>${escapeHTML(runCommand)}</code><button type="button" data-copy-command>复制命令</button></div>
            </section>` : ""}
        </aside>
      </div>`;

    const copyCommand = panel.querySelector("[data-copy-command]");
    if (copyCommand) copyCommand.addEventListener("click", (event) => copyText(runCommand, event.currentTarget));
  }

  async function renderSelectedFile(file) {
    const viewer = document.querySelector("#file-viewer");
    if (!viewer) return;
    viewer.dataset.path = file.path;
    viewer.innerHTML = `<div class="file-loading"><div class="loading-mark"></div><p>正在加载 ${escapeHTML(file.name)}…</p></div>`;

    try {
      const source = await fetchText(file.path);
      const currentViewer = document.querySelector("#file-viewer");
      if (!currentViewer || currentViewer.dataset.path !== file.path) return;
      const profile = sourceProfile(file.path);
      const rawURL = absoluteURL(file.path);
      const runCommand = profile.executor ? `curl -fsSL ${rawURL} | ${profile.executor}` : null;
      currentViewer.innerHTML = `
        <div class="source-toolbar">
          <div><strong>${escapeHTML(file.name)}</strong><span>${sourceLineCount(source)} 行</span><span>${escapeHTML(profile.language)}</span></div>
          <div>
            <a href="${escapeHTML(rawURL)}" target="_blank" rel="noopener">Raw</a>
            ${runCommand ? `<button type="button" data-copy-file-command>复制执行命令</button>` : ""}
            <button type="button" data-copy-file-source>复制源码</button>
          </div>
        </div>
        <pre class="source-view"><code class="language-${escapeHTML(profile.language)}">${sourceLines(source, profile.language)}</code></pre>`;

      currentViewer.querySelector("[data-copy-file-source]").addEventListener("click", (event) => copyText(source, event.currentTarget));
      const copyCommand = currentViewer.querySelector("[data-copy-file-command]");
      if (copyCommand) copyCommand.addEventListener("click", (event) => copyText(runCommand, event.currentTarget));
    } catch (error) {
      viewer.innerHTML = `<div class="file-error"><strong>文件加载失败</strong><p>${escapeHTML(error.message)}</p></div>`;
    }
  }

  function renderFiles(script, selectedIndex = 0) {
    const panel = document.querySelector("#tab-panel");
    const selectedFile = script.files[selectedIndex] || script.files[0];
    panel.innerHTML = `
      <div class="files-layout">
        <aside class="file-list" aria-label="文件列表">
          <div class="file-list-heading">文件 <span>${script.files.length}</span></div>
          ${script.files.map((file, index) => `
            <button class="file-item${index === selectedIndex ? " is-active" : ""}" type="button" data-file-index="${index}">
              <span class="file-icon" aria-hidden="true">&lt;/&gt;</span>
              <span><strong>${escapeHTML(file.label)}</strong><small>${file.os.map(escapeHTML).join(" / ")}</small></span>
            </button>`).join("")}
        </aside>
        <section class="file-viewer" id="file-viewer" aria-live="polite"></section>
      </div>`;

    panel.querySelectorAll("[data-file-index]").forEach((button) => {
      button.addEventListener("click", () => renderFiles(script, Number(button.dataset.fileIndex)));
    });
    renderSelectedFile(selectedFile);
  }

  function renderScript(id) {
    const script = state.scripts.find((item) => item.id === id);
    if (!script) {
      renderNotFound();
      return;
    }

    document.title = `${script.title} — Awesome Script Hub`;
    app.className = "detail-page shell";
    const frontMatter = state.documents.get(script.id);
    if (!frontMatter) {
      renderError("无法加载脚本详情", `未加载 ${scriptPaths(script.id).doc}`);
      return;
    }

    app.innerHTML = `
      <nav class="breadcrumb" aria-label="面包屑"><a href="#/">脚本库</a><span>/</span><span>${escapeHTML(script.id)}</span></nav>
      <header class="detail-header">
        <h1>${escapeHTML(script.title)}</h1>
        <p>${escapeHTML(script.description)}</p>
      </header>
      <nav class="detail-tabs" role="tablist" aria-label="脚本内容">
        <button class="is-active" type="button" role="tab" aria-selected="true" data-detail-tab="intro">介绍</button>
        <button type="button" role="tab" aria-selected="false" data-detail-tab="files">文件 <span>${script.files.length}</span></button>
      </nav>
      <div class="tab-panel" id="tab-panel" role="tabpanel"></div>`;

    const tabs = app.querySelectorAll("[data-detail-tab]");
    tabs.forEach((tab) => tab.addEventListener("click", () => {
      tabs.forEach((item) => {
        const active = item === tab;
        item.classList.toggle("is-active", active);
        item.setAttribute("aria-selected", String(active));
      });
      if (tab.dataset.detailTab === "files") renderFiles(script);
      else renderIntroduction(script, frontMatter);
    }));
    renderIntroduction(script, frontMatter);
  }

  function renderNotFound() {
    document.title = "页面不存在 — Awesome Script Hub";
    app.className = "status-page shell";
    app.innerHTML = `<span class="status-code">404</span><h1>这里没有脚本</h1><p>链接可能已失效，或者脚本尚未加入索引。</p><a class="button primary" href="#/">返回脚本库</a>`;
  }

  function renderError(title, detail) {
    app.className = "status-page shell";
    app.innerHTML = `<span class="status-code">ERROR</span><h1>${escapeHTML(title)}</h1><p>${escapeHTML(detail)}</p><button class="button primary" id="reload-page" type="button">重新加载</button>`;
    document.querySelector("#reload-page").addEventListener("click", () => window.location.reload());
  }

  function renderRoute(route) {
    document.removeEventListener("keydown", focusSearch);
    if (route.name === "home") renderHome();
    else if (route.name === "script") renderScript(route.params.id);
    else renderNotFound();
  }

  async function init() {
    initTheme();
    try {
      state.scripts = await loadCatalog();
      window.Router.subscribe(renderRoute);
      window.Router.start();
    } catch (error) {
      renderError("脚本索引加载失败", `${error.message}。请通过 HTTP 服务访问，不要直接双击 index.html。`);
    }
  }

  init();
})();
