/*
 * o-feedback.js — Vorflux-style visual feedback widget for O v4.
 *
 * Self-contained vanilla JS, no dependencies, no build step. Drop it onto any
 * dev page; Alt+Shift+A toggles annotate mode. Point at a hovered element,
 * click it, type an instruction, and it batches locally. "Send to O" POSTs the
 * batch to the O daemon, which files ONE origin='feedback' issue.
 *
 * Config (first found wins):
 *   window.O_FEEDBACK = { endpoint: "http://127.0.0.1:4100", company: "co_..." }
 *   data-endpoint / data-company attributes on this <script> tag
 *
 * Zero external requests besides the configured endpoint. All styling is
 * inlined into one injected <style> under the o-fb- namespace so the host
 * page's own CSS is never touched.
 */
(function () {
  "use strict";

  if (window.OFeedback && window.OFeedback.__installed) return;

  // ---- config ------------------------------------------------------------
  var script = document.currentScript;
  var cfg = window.O_FEEDBACK || {};
  var ENDPOINT = (cfg.endpoint ||
    (script && script.getAttribute("data-endpoint")) ||
    "http://127.0.0.1:4100").replace(/\/+$/, "");
  var COMPANY = cfg.company ||
    (script && script.getAttribute("data-company")) ||
    "";

  var batch = [];
  var batchKey = ""; // Idempotency-Key for the batch as it stands; reset when it changes
  var active = false;
  var overlayEl = null;     // hover highlight
  var inputWrap = null;     // floating instruction input
  var pendingTarget = null; // element awaiting an instruction

  // ---- styles ------------------------------------------------------------
  var CSS = [
    ".o-fb-overlay{position:absolute;z-index:2147483640;pointer-events:none;",
    "  outline:2px solid #d1495b;background:rgba(209,73,91,0.12);border-radius:2px;",
    "  transition:all 40ms linear;box-sizing:border-box;}",
    ".o-fb-input{position:absolute;z-index:2147483646;background:#fff;color:#1a1a1a;",
    "  border:1px solid #d1495b;border-radius:8px;padding:8px;box-shadow:0 8px 28px rgba(0,0,0,0.28);",
    "  font:14px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;width:280px;}",
    ".o-fb-input input{width:100%;box-sizing:border-box;border:1px solid #ddd;border-radius:6px;",
    "  padding:7px 9px;font:14px/1.4 inherit;color:#1a1a1a;background:#fff;outline:none;}",
    ".o-fb-input .o-fb-hint{margin-top:6px;font-size:11px;color:#888;}",
    ".o-fb-panel{position:fixed;bottom:20px;right:20px;z-index:2147483645;width:320px;",
    "  max-height:70vh;display:flex;flex-direction:column;background:#fff;color:#1a1a1a;",
    "  border-radius:12px;box-shadow:0 12px 40px rgba(0,0,0,0.30);overflow:hidden;",
    "  font:13px/1.45 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;}",
    ".o-fb-head{display:flex;align-items:center;justify-content:space-between;",
    "  padding:11px 14px;background:#1a1a1a;color:#fff;}",
    ".o-fb-head b{font-size:13px;font-weight:600;letter-spacing:0.2px;}",
    ".o-fb-badge{background:#d1495b;color:#fff;border-radius:10px;padding:1px 8px;font-size:11px;margin-left:8px;}",
    ".o-fb-mode{font-size:11px;opacity:0.7;}",
    ".o-fb-list{flex:1;overflow-y:auto;padding:6px 10px;}",
    ".o-fb-item{border:1px solid #eee;border-radius:8px;padding:8px 10px;margin:6px 0;}",
    ".o-fb-item .o-fb-sel{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;",
    "  font-size:11px;color:#8a5a00;word-break:break-all;}",
    ".o-fb-item .o-fb-ins{margin-top:3px;color:#1a1a1a;}",
    ".o-fb-item .o-fb-rm{float:right;cursor:pointer;color:#bbb;font-size:15px;line-height:1;margin-left:6px;}",
    ".o-fb-item .o-fb-rm:hover{color:#d1495b;}",
    ".o-fb-empty{color:#999;text-align:center;padding:18px 8px;font-size:12px;}",
    ".o-fb-foot{display:flex;gap:8px;padding:10px 12px;border-top:1px solid #eee;}",
    ".o-fb-btn{flex:1;border:0;border-radius:8px;padding:9px;font:600 13px inherit;cursor:pointer;}",
    ".o-fb-send{background:#d1495b;color:#fff;}",
    ".o-fb-send:hover{background:#b83a4b;}.o-fb-send:disabled{background:#e6a3ad;cursor:default;}",
    ".o-fb-clear{background:#f0f0f0;color:#333;}.o-fb-clear:hover{background:#e4e4e4;}",
    ".o-fb-toast{position:fixed;bottom:20px;left:20px;z-index:2147483646;background:#1a1a1a;color:#fff;",
    "  padding:10px 16px;border-radius:8px;font:13px/1.4 -apple-system,sans-serif;",
    "  box-shadow:0 8px 28px rgba(0,0,0,0.3);opacity:0;transition:opacity 160ms;}",
    ".o-fb-toast.on{opacity:1;}"
  ].join("");

  function injectStyle() {
    if (document.getElementById("o-fb-style")) return;
    var s = document.createElement("style");
    s.id = "o-fb-style";
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  }

  // ---- selector path -----------------------------------------------------
  // id short-circuits; otherwise tag.classes:nth-of-type chained up to body.
  function cssPath(el) {
    if (!el || el.nodeType !== 1) return "";
    if (el.id) return "#" + cssEscape(el.id);
    var parts = [];
    var node = el;
    while (node && node.nodeType === 1 && node.tagName.toLowerCase() !== "body") {
      var sel = node.tagName.toLowerCase();
      if (node.classList && node.classList.length) {
        var cls = Array.prototype.slice.call(node.classList)
          .filter(function (c) { return c.indexOf("o-fb-") !== 0; })
          .map(cssEscape);
        if (cls.length) sel += "." + cls.join(".");
      }
      var parent = node.parentNode;
      if (parent && parent.children) {
        var same = Array.prototype.filter.call(parent.children, function (c) {
          return c.tagName === node.tagName;
        });
        if (same.length > 1) {
          sel += ":nth-of-type(" + (same.indexOf(node) + 1) + ")";
        }
      }
      parts.unshift(sel);
      if (node.id) { parts[0] = "#" + cssEscape(node.id); break; }
      node = node.parentNode;
    }
    return parts.join(" > ");
  }

  function cssEscape(s) {
    if (window.CSS && CSS.escape) { try { return window.CSS.escape(s); } catch (e) {} }
    return String(s).replace(/([^a-zA-Z0-9_-])/g, "\\$1");
  }

  // ---- computed styles subset -------------------------------------------
  var STYLE_KEYS = ["color", "background-color", "font-size", "font-family",
    "font-weight", "display", "position", "margin", "padding",
    "width", "height"];

  function captureStyles(el) {
    var cs = window.getComputedStyle(el);
    var out = {};
    for (var i = 0; i < STYLE_KEYS.length; i++) {
      out[STYLE_KEYS[i]] = cs.getPropertyValue(STYLE_KEYS[i]);
    }
    return out;
  }

  // ---- overlay -----------------------------------------------------------
  function ensureOverlay() {
    if (overlayEl) return overlayEl;
    overlayEl = document.createElement("div");
    overlayEl.className = "o-fb-overlay";
    overlayEl.style.display = "none";
    document.body.appendChild(overlayEl);
    return overlayEl;
  }

  function moveOverlay(el) {
    var ov = ensureOverlay();
    var r = el.getBoundingClientRect();
    ov.style.display = "block";
    ov.style.top = (r.top + window.scrollY) + "px";
    ov.style.left = (r.left + window.scrollX) + "px";
    ov.style.width = r.width + "px";
    ov.style.height = r.height + "px";
  }

  function hideOverlay() {
    if (overlayEl) overlayEl.style.display = "none";
  }

  function isOurs(el) {
    return el && el.closest &&
      (el.closest(".o-fb-panel") || el.closest(".o-fb-input") ||
        el.classList.contains("o-fb-overlay") || el.classList.contains("o-fb-toast"));
  }

  // ---- event handlers ----------------------------------------------------
  function onMove(e) {
    if (!active || pendingTarget) return;
    var el = e.target;
    if (isOurs(el)) { hideOverlay(); return; }
    moveOverlay(el);
  }

  function onClick(e) {
    if (!active || pendingTarget) return;
    var el = e.target;
    if (isOurs(el)) return;
    e.preventDefault();
    e.stopPropagation();
    pendingTarget = el;
    openInput(e.clientX + window.scrollX, e.clientY + window.scrollY);
  }

  function openInput(x, y) {
    closeInput();
    inputWrap = document.createElement("div");
    inputWrap.className = "o-fb-input";
    inputWrap.style.top = y + "px";
    inputWrap.style.left = Math.min(x, window.scrollX + window.innerWidth - 300) + "px";
    var inp = document.createElement("input");
    inp.type = "text";
    inp.placeholder = "What should change here?";
    var hint = document.createElement("div");
    hint.className = "o-fb-hint";
    hint.textContent = "Enter to save · Esc to cancel";
    inputWrap.appendChild(inp);
    inputWrap.appendChild(hint);
    document.body.appendChild(inputWrap);
    inp.focus();
    inp.addEventListener("keydown", function (ev) {
      if (ev.key === "Enter") {
        ev.preventDefault();
        var v = inp.value.trim();
        if (v) saveAnnotation(pendingTarget, v);
        closeInput();
        pendingTarget = null;
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        ev.stopPropagation();
        closeInput();
        pendingTarget = null;
      }
    });
  }

  function closeInput() {
    if (inputWrap && inputWrap.parentNode) inputWrap.parentNode.removeChild(inputWrap);
    inputWrap = null;
  }

  function saveAnnotation(el, instruction) {
    batchKey = "";
    batch.push({
      selector: cssPath(el),
      html: (el.outerHTML || "").slice(0, 2000),
      styles: captureStyles(el),
      instruction: instruction
    });
    renderPanel();
  }

  function onKey(e) {
    if (e.altKey && e.shiftKey && (e.code === "KeyA" || e.key === "A" || e.key === "a")) {
      e.preventDefault();
      toggle();
    } else if (e.key === "Escape" && active && !pendingTarget) {
      setActive(false);
    }
  }

  // ---- mode --------------------------------------------------------------
  function setActive(on) {
    active = on;
    if (!on) { hideOverlay(); closeInput(); pendingTarget = null; }
    renderPanel();
  }
  function toggle() { ensurePanel(); setActive(!active); }

  // ---- panel -------------------------------------------------------------
  var panel = null;
  function ensurePanel() {
    injectStyle();
    if (panel) return panel;
    panel = document.createElement("div");
    panel.className = "o-fb-panel";
    document.body.appendChild(panel);
    renderPanel();
    return panel;
  }

  function renderPanel() {
    if (!panel) return;
    panel.innerHTML = "";
    var head = document.createElement("div");
    head.className = "o-fb-head";
    var left = document.createElement("div");
    left.innerHTML = "<b>O feedback</b><span class='o-fb-badge'>" + batch.length + "</span>";
    var mode = document.createElement("div");
    mode.className = "o-fb-mode";
    mode.textContent = active ? "annotating — click an element" : "Alt+Shift+A";
    head.appendChild(left);
    head.appendChild(mode);
    panel.appendChild(head);

    var list = document.createElement("div");
    list.className = "o-fb-list";
    if (!batch.length) {
      var empty = document.createElement("div");
      empty.className = "o-fb-empty";
      empty.textContent = "No annotations yet. Toggle annotate mode and click elements to flag.";
      list.appendChild(empty);
    } else {
      batch.forEach(function (a, i) {
        var item = document.createElement("div");
        item.className = "o-fb-item";
        var rm = document.createElement("span");
        rm.className = "o-fb-rm";
        rm.textContent = "×";
        rm.title = "remove";
        rm.addEventListener("click", function () { batch.splice(i, 1); batchKey = ""; renderPanel(); });
        var sel = document.createElement("div");
        sel.className = "o-fb-sel";
        sel.textContent = a.selector;
        var ins = document.createElement("div");
        ins.className = "o-fb-ins";
        ins.textContent = a.instruction;
        item.appendChild(rm);
        item.appendChild(sel);
        item.appendChild(ins);
        list.appendChild(item);
      });
    }
    panel.appendChild(list);

    var foot = document.createElement("div");
    foot.className = "o-fb-foot";
    var send = document.createElement("button");
    send.className = "o-fb-btn o-fb-send";
    send.textContent = "Send to O";
    send.disabled = !batch.length;
    send.addEventListener("click", sendBatch);
    var clear = document.createElement("button");
    clear.className = "o-fb-btn o-fb-clear";
    clear.textContent = "Clear";
    clear.addEventListener("click", function () { batch = []; batchKey = ""; renderPanel(); });
    foot.appendChild(send);
    foot.appendChild(clear);
    panel.appendChild(foot);
  }

  // ---- send --------------------------------------------------------------
  function sendBatch() {
    if (!batch.length) return;
    if (!COMPANY) { toast("Set O_FEEDBACK.company first"); return; }
    var payload = { page_url: location.href, annotations: batch.slice() };
    // one key per batch until it is filed: resending after a dropped
    // response returns the same issue instead of filing a second one
    if (!batchKey) batchKey = "fb-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
    fetch(ENDPOINT + "/api/companies/" + encodeURIComponent(COMPANY) + "/feedback", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Idempotency-Key": batchKey },
      body: JSON.stringify(payload)
    }).then(function (r) {
      return r.json().then(function (d) { return { ok: r.status === 201, d: d }; });
    }).then(function (res) {
      if (res.ok) {
        var ident = res.d.identifier || res.d.id || "issue";
        toast("Filed " + ident + " ✓");
        batch = [];
        batchKey = "";
        renderPanel();
      } else {
        toast("Error: " + ((res.d && res.d.error) || "could not file"));
      }
    }).catch(function (err) {
      toast("Network error: " + err.message);
    });
  }

  // ---- toast -------------------------------------------------------------
  var toastEl = null, toastT = null;
  function toast(msg) {
    if (!toastEl) {
      toastEl = document.createElement("div");
      toastEl.className = "o-fb-toast";
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = msg;
    toastEl.classList.add("on");
    clearTimeout(toastT);
    toastT = setTimeout(function () { toastEl.classList.remove("on"); }, 2600);
  }

  // ---- boot --------------------------------------------------------------
  function boot() {
    injectStyle();
    document.addEventListener("mousemove", onMove, true);
    document.addEventListener("click", onClick, true);
    document.addEventListener("keydown", onKey, true);
    ensurePanel();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }

  window.OFeedback = {
    __installed: true,
    toggle: toggle,
    open: function () { ensurePanel(); setActive(true); },
    close: function () { setActive(false); },
    clear: function () { batch = []; batchKey = ""; renderPanel(); },
    batch: function () { return batch.slice(); },
    config: function () { return { endpoint: ENDPOINT, company: COMPANY }; }
  };
})();
