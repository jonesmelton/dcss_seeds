// Loaded synchronously in <head>, before paint: a theme applied after first
// paint flashes the wrong one. The CSP forbids an inline script, so this is a
// separate file rather than the usual blocking snippet.
(function () {
  var KEY = "theme";
  var root = document.documentElement;

  function apply(choice) {
    if (choice === "dark" || choice === "light") root.setAttribute("data-theme", choice);
    else root.removeAttribute("data-theme");
  }

  try {
    apply(localStorage.getItem(KEY));
  } catch (e) {
    // Private browsing or a blocked origin: fall through to the OS preference,
    // which needs no attribute at all.
  }

  function stored() {
    try {
      return localStorage.getItem(KEY) || "auto";
    } catch (e) {
      return "auto";
    }
  }

  function sync(group) {
    var current = stored();
    var buttons = group.querySelectorAll("button[data-theme-choice]");
    for (var i = 0; i < buttons.length; i++) {
      var choice = buttons[i].getAttribute("data-theme-choice");
      buttons[i].setAttribute("aria-pressed", String(choice === current));
    }
  }

  function wire() {
    var group = document.querySelector(".theme-toggle");
    if (!group) return;
    sync(group);
    group.addEventListener("click", function (event) {
      var button = event.target.closest("button[data-theme-choice]");
      if (!button) return;
      var choice = button.getAttribute("data-theme-choice");
      try {
        if (choice === "auto") localStorage.removeItem(KEY);
        else localStorage.setItem(KEY, choice);
      } catch (e) {
        // Not persistable; still apply for this page.
      }
      apply(choice);
      sync(group);
    });
  }

  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", wire);
  else wire();
})();
