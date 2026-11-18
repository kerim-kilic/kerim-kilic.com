// Colour theme toggle: light or dark. Until the visitor chooses, the site follows the system setting.
// Choosing the theme the system already uses clears the saved choice, so the site follows the system again.
// Loaded in <head> without defer, so a saved choice applies before the first paint (no flash).
// Without JavaScript the button stays hidden and the site follows the system setting.
(function () {
  var KEY = "theme";
  var root = document.documentElement;
  var system = window.matchMedia("(prefers-color-scheme: dark)");
  var metas = document.querySelectorAll('meta[name="theme-color"]');
  var colours = {};
  for (var i = 0; i < metas.length; i++) {
    metas[i].dataset.media = metas[i].media;
    metas[i].dataset.content = metas[i].content;
    colours[metas[i].media.indexOf("dark") > -1 ? "dark" : "light"] = metas[i].content;
  }

  var saved = null;
  try {
    saved = localStorage.getItem(KEY);
    if (saved !== "light" && saved !== "dark") saved = null;
  } catch (e) { /* storage blocked: follow the system */ }

  function current() { return saved || (system.matches ? "dark" : "light"); }

  function apply() {
    if (saved) root.setAttribute("data-theme", saved);
    else root.removeAttribute("data-theme");
    // Keep the browser's address-bar colour in step with a saved choice.
    for (var i = 0; i < metas.length; i++) {
      var m = metas[i];
      m.media = saved ? "all" : m.dataset.media;
      m.content = saved ? colours[saved] : m.dataset.content;
    }
  }

  apply();

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.querySelector(".theme-toggle");
    if (!button) return;
    var label = button.querySelector(".theme-label");

    // The icon and label show the theme a click switches to.
    function render() {
      var next = current() === "dark" ? "light" : "dark";
      button.dataset.next = next;
      label.textContent = "Switch to " + next + " theme";
      button.title = label.textContent;
    }

    button.addEventListener("click", function () {
      var next = current() === "dark" ? "light" : "dark";
      saved = next === (system.matches ? "dark" : "light") ? null : next;
      try {
        if (saved) localStorage.setItem(KEY, saved);
        else localStorage.removeItem(KEY);
      } catch (e) { /* not saved, still applies to this page */ }
      apply();
      render();
    });

    // A system change matters only while no choice is saved.
    if (system.addEventListener) system.addEventListener("change", render);

    render();
    button.hidden = false;
  });
})();
