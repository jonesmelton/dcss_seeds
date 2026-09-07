// Delegated from the document, not bound per button: htmx swaps fragments in,
// and rebinding after every swap is one hx-trigger away from being forgotten.
(function () {
  var RESTORE_MS = 1200;

  function fallback(text) {
    // navigator.clipboard is undefined outside a secure context, which includes
    // a plain-http LAN host -- the way this app is usually reached.
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try {
      ok = document.execCommand("copy");
    } catch (e) {
      ok = false;
    }
    document.body.removeChild(area);
    return ok ? Promise.resolve() : Promise.reject(new Error("copy failed"));
  }

  function write(text) {
    if (navigator.clipboard && window.isSecureContext)
      return navigator.clipboard.writeText(text);
    return fallback(text);
  }

  // Class, not textContent: the button's label is an svg glyph, and rewriting
  // the text would delete it. The accessible name is rewritten alongside, so
  // the confirmation is not carried by the glyph alone.
  function flash(button, state) {
    if (button.dataset.restore) window.clearTimeout(Number(button.dataset.restore));
    else button.dataset.label = button.getAttribute("aria-label");
    var word =
      state === "is-done"
        ? button.getAttribute("data-copy-done")
        : button.getAttribute("data-copy-fail");
    button.classList.remove("is-done", "is-failed");
    button.classList.add(state);
    if (word) {
      button.setAttribute("aria-label", word);
      button.setAttribute("title", word);
    }
    button.dataset.restore = String(
      window.setTimeout(function () {
        button.classList.remove("is-done", "is-failed");
        button.setAttribute("aria-label", button.dataset.label);
        button.setAttribute("title", button.dataset.label);
        delete button.dataset.restore;
      }, RESTORE_MS)
    );
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest("button[data-copy]");
    if (!button) return;
    event.preventDefault();
    write(button.getAttribute("data-copy")).then(
      function () {
        flash(button, "is-done");
      },
      function () {
        flash(button, "is-failed");
      }
    );
  });
})();
