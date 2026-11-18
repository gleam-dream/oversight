// Browser APIs the site needs and nothing else: storage, media queries,
// location, timers, scrolling, measurement and one animation-frame loop.
import { toList } from "../gleam.mjs";

export function storage_get(key) {
  try {
    const value = window.localStorage.getItem(key);
    return value === null ? [false, ""] : [true, value];
  } catch {
    return [false, ""];
  }
}

export function storage_set(key, value) {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // Storage can be unavailable (private mode, blocked); the site still works.
  }
}

export function prefers_reduced_motion() {
  try {
    return !!(
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  } catch {
    return false;
  }
}

export function location_hash() {
  return window.location.hash;
}

export function on_hash_change(callback) {
  window.addEventListener("hashchange", () => callback(window.location.hash));
}

export function on_resize(callback) {
  window.addEventListener("resize", () => callback());
}

export function on_fonts_ready(callback) {
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => callback());
  }
}

export function set_timeout(ms, callback) {
  window.setTimeout(() => callback(), ms);
}

export function set_document_title(title) {
  document.title = title;
}

export function scroll_to_top() {
  window.scrollTo(0, 0);
}

export function focus_without_scroll(id) {
  const element = document.getElementById(id);
  if (element) element.focus({ preventScroll: true });
}

function app_bar_height() {
  const bar = document.querySelector(".appbar");
  return bar ? bar.getBoundingClientRect().height : 0;
}

export function scroll_into_view(id, smooth) {
  const element = document.getElementById(id);
  if (element) {
    element.scrollIntoView({
      behavior: smooth ? "smooth" : "auto",
      block: "start",
    });
  }
}

// Bring a playground card to just under the sticky app bar, after the next
// paint so the card's new size is measured.
export function scroll_under_app_bar(selector, smooth) {
  requestAnimationFrame(() =>
    requestAnimationFrame(() => {
      const element = document.querySelector(selector);
      if (!element) return;
      const top = element.getBoundingClientRect().top;
      const want = app_bar_height() + 10;
      if (Math.abs(top - want) > 24) {
        window.scrollTo({
          top: window.scrollY + top - want,
          behavior: smooth ? "smooth" : "auto",
        });
      }
    }),
  );
}

// Measure every playground card that is touring: its tour id, the narration
// it shows, its height and the tour bar's height including its margin.
export function measure_labs() {
  const available = Math.floor(window.innerHeight - app_bar_height() - 16);
  const labs = Array.from(document.querySelectorAll("#view .lab.touring")).map(
    (lab) => {
      const bar = lab.querySelector(".tourbar");
      const text = lab.querySelector(".tourtext");
      const barHeight = bar
        ? bar.getBoundingClientRect().height +
          parseFloat(getComputedStyle(bar).marginBottom || "0")
        : 0;
      return [
        lab.getAttribute("data-tid") || "",
        text ? text.textContent : "",
        Math.ceil(lab.getBoundingClientRect().height),
        Math.ceil(barHeight),
      ];
    },
  );
  return [window.innerWidth, window.innerHeight, available, toList(labs)];
}

// One requestAnimationFrame loop for every real-time widget. It runs only
// while something is subscribed and skips frames while the tab is hidden.
const subscribers = new Map();
let nextId = 1;
let running = false;
let last = 0;

function loop(timestamp) {
  if (subscribers.size === 0) {
    running = false;
    last = 0;
    return;
  }
  requestAnimationFrame(loop);
  const dt = last ? Math.min(0.05, (timestamp - last) / 1000) : 0;
  last = timestamp;
  if (document.hidden) return;
  for (const callback of Array.from(subscribers.values())) callback(dt);
}

export function subscribe_frames(callback) {
  const id = nextId++;
  subscribers.set(id, callback);
  if (!running) {
    running = true;
    requestAnimationFrame(loop);
  }
  return id;
}

export function unsubscribe_frames(id) {
  subscribers.delete(id);
}
