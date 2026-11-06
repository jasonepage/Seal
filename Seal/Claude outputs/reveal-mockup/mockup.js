const ready = document.getElementById("ready");
const opening = document.getElementById("opening");
const stage = document.getElementById("reveal-stage");
const status = document.getElementById("opening-status");
const content = document.getElementById("reveal-content");
const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
const timers = [];

function later(fn, ms) {
  const id = window.setTimeout(fn, ms);
  timers.push(id);
}

function reset() {
  timers.splice(0).forEach(window.clearTimeout);
  ready.hidden = false;
  opening.hidden = true;
  content.hidden = true;
  content.className = "reveal-content";
  stage.className = "reveal-stage is-sealed";
  status.textContent = "Opening your envelope...";
  const secret = document.getElementById("secret");
  secret.className = "secret-turn is-hidden";
  secret.querySelector(".secret-front").setAttribute("aria-hidden", "false");
  secret.querySelector(".secret-back").setAttribute("aria-hidden", "true");
  document.getElementById("copy-status").textContent = "";
  ready.scrollIntoView({ behavior:"auto", block:"start" });
}

function openEnvelope() {
  ready.hidden = true;
  opening.hidden = false;
  opening.scrollIntoView({ behavior:"smooth", block:"start" });

  if (reduce.matches) {
    later(() => {
      stage.className = "reveal-stage is-open";
      status.textContent = "Your envelope is open.";
      content.hidden = false;
      requestAnimationFrame(() => content.classList.add("is-visible"));
      stage.querySelector(".reveal-title").focus();
    }, 180);
    return;
  }

  requestAnimationFrame(() => requestAnimationFrame(() => stage.classList.add("is-cracking")));
  later(() => stage.classList.add("is-opening"), 220);
  later(() => stage.classList.add("is-rising"), 500);
  later(() => stage.classList.add("is-reading"), 920);
  later(() => {
    stage.className = "reveal-stage is-open";
    status.textContent = "Your envelope is open.";
    content.hidden = false;
    requestAnimationFrame(() => content.classList.add("is-visible"));
    stage.querySelector(".reveal-title").focus();
  }, 1500);
}

document.getElementById("open").addEventListener("click", openEnvelope);
document.getElementById("reset").addEventListener("click", reset);

document.getElementById("reveal-secret").addEventListener("click", () => {
  const secret = document.getElementById("secret");
  secret.className = "secret-turn is-revealed";
  secret.querySelector(".secret-front").setAttribute("aria-hidden", "true");
  secret.querySelector(".secret-back").setAttribute("aria-hidden", "false");
  later(() => secret.querySelector(".secret-value").focus(), reduce.matches ? 1 : 520);
});
document.getElementById("hide-secret").addEventListener("click", () => {
  const secret = document.getElementById("secret");
  secret.className = "secret-turn is-hidden";
  secret.querySelector(".secret-front").setAttribute("aria-hidden", "false");
  secret.querySelector(".secret-back").setAttribute("aria-hidden", "true");
  document.getElementById("reveal-secret").focus();
});
document.getElementById("copy-secret").addEventListener("click", async () => {
  const line = document.getElementById("copy-status");
  try {
    await navigator.clipboard.writeText("FOUND-500-WINNER");
    line.textContent = "Copied. A browser cannot clear your clipboard, so copy something else after you paste it.";
  } catch {
    line.textContent = "This browser would not copy. Select the code and copy it by hand.";
  }
});

document.getElementById("voice-play").addEventListener("click", (event) => {
  const panel = event.currentTarget.closest(".reveal-voice");
  const playing = panel.classList.toggle("is-playing");
  document.getElementById("voice-label").textContent = playing ? "Pause voice message" : "Play the voice message";
  event.currentTarget.setAttribute("aria-label", playing ? "Pause voice message" : "Play the voice message");
});
