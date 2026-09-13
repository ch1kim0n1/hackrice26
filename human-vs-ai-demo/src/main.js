import { initHumanPanel } from "./human.js";
import { initAgentPanel } from "./agent.js";
import { startMonitor } from "./monitor.js";

const $ = (sel) => document.querySelector(sel);

// The one video everyone means when they say "rickroll" — embedded via
// YouTube's own iframe embed endpoint, nothing proxied or re-hosted here.
const RICKROLL_VIDEO_ID = "dQw4w9WgXcQ";

const rickroll = $("#rickroll-overlay");
const rickrollStage1 = rickroll.querySelector("[data-rickroll-stage='1']");
const rickrollStage2 = rickroll.querySelector("[data-rickroll-stage='2']");
const rickrollVideo = rickroll.querySelector("[data-rickroll-video]");
const rickrollUnmute = rickroll.querySelector("[data-rickroll-unmute]");

function embedUrl(muted) {
  const params = new URLSearchParams({
    autoplay: "1",
    mute: muted ? "1" : "0",
    controls: "1",
    rel: "0",
  });
  return `https://www.youtube.com/embed/${RICKROLL_VIDEO_ID}?${params}`;
}

function showRickroll() {
  rickroll.hidden = false;
  rickrollStage1.hidden = false;
  rickrollStage2.hidden = true;
  rickrollUnmute.hidden = false;
  setTimeout(() => {
    rickrollStage1.hidden = true;
    rickrollStage2.hidden = false;
    // Muted autoplay by default — browsers allow it without a user gesture,
    // and it won't blast audio mid-presentation unless you hit Unmute.
    rickrollVideo.src = embedUrl(true);
  }, 1400);
}

rickrollUnmute.addEventListener("click", () => {
  rickrollVideo.src = embedUrl(false);
  rickrollUnmute.hidden = true;
});

rickroll.querySelector("[data-rickroll-close]").addEventListener("click", () => {
  rickroll.hidden = true;
  rickrollVideo.src = ""; // stop playback when closed
});

initHumanPanel($("#human-panel"));
initAgentPanel($("#agent-panel"), { onRickroll: showRickroll });
startMonitor($("#security-log"));
