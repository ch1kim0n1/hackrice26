// Round engine — renders a challenge spec into the arena, captures
// high-resolution timing + pointer-trajectory telemetry, resolves
// a RoundResult for scoring.

/**
 * @param {HTMLElement} arena
 * @param {object} spec          round spec from challenge.js
 * @param {object} [callbacks]   {onHit(rt), onDecoy(), onMiss()} for juice
 * @returns {Promise<object>}    RoundResult
 */
export function playRound(arena, spec, callbacks = {}) {
  return new Promise((resolve) => {
    const t0 = performance.now();
    const rect = () => arena.getBoundingClientRect();

    const result = {
      spec,
      hits: [],
      misses: [],
      wrongOrder: 0,
      decoyTaps: 0,
      strayTaps: 0,
      trail: [],
      startedAt: t0,
      endedAt: 0,
      pointerTypes: new Set(),
    };

    const pendingTimers = new Set();
    const liveOrbs = new Map(); // targetId -> {el, state}
    let expectedSeq = 1;
    let resolvedTargets = 0;
    let appearedCount = 0;
    let finished = false;

    // ---- pointer trail (trajectory signal) ----
    let lastSample = 0;
    const onMove = (e) => {
      const now = performance.now();
      if (now - lastSample < 14) return; // ~60hz cap
      lastSample = now;
      result.trail.push({ t: now - t0, x: e.clientX, y: e.clientY, pt: e.pointerType });
    };
    arena.addEventListener("pointermove", onMove);

    // ---- stray taps on empty arena ----
    const onArenaDown = (e) => {
      if (e.target === arena) {
        result.strayTaps++;
        result.pointerTypes.add(e.pointerType);
      }
    };
    arena.addEventListener("pointerdown", onArenaDown);

    // ---- helpers ----
    const burst = (x, y, color) => {
      for (let i = 0; i < 8; i++) {
        const p = document.createElement("div");
        p.className = "burst";
        p.style.left = `${x}%`;
        p.style.top = `${y}%`;
        p.style.background = color;
        p.style.setProperty("--a", `${(360 / 8) * i}deg`);
        arena.appendChild(p);
        setTimeout(() => p.remove(), 600);
      }
    };

    const chip = (x, y, text) => {
      const c = document.createElement("div");
      c.className = "rt-chip";
      c.style.left = `${x}%`;
      c.style.top = `${y}%`;
      c.textContent = text;
      arena.appendChild(c);
      setTimeout(() => c.remove(), 750);
    };

    const schedule = (fn, ms) => {
      const id = setTimeout(() => {
        pendingTimers.delete(id);
        fn();
      }, ms);
      pendingTimers.add(id);
    };

    const checkEnd = () => {
      if (finished) return;
      const allResolved = resolvedTargets >= spec.expectedHits;
      const allAppeared = appearedCount >= spec.targets.length;
      if (allResolved && allAppeared) finish();
    };

    const finish = () => {
      finished = true;
      pendingTimers.forEach(clearTimeout);
      arena.removeEventListener("pointermove", onMove);
      arena.removeEventListener("pointerdown", onArenaDown);
      result.endedAt = performance.now();
      result.pointerTypes = [...result.pointerTypes];
      // let the last burst animation breathe before teardown
      setTimeout(() => {
        arena.innerHTML = "";
        resolve(result);
      }, 220);
    };

    const resolveTarget = (targetId, cls, counts = true) => {
      const orb = liveOrbs.get(targetId);
      if (!orb) return;
      liveOrbs.delete(targetId);
      if (counts) resolvedTargets++;
      orb.el.classList.add(cls);
      setTimeout(() => orb.el.remove(), 320);
      checkEnd();
    };

    // ---- orb lifecycle ----
    const appear = (target) => {
      if (finished) return;
      appearedCount++;
      const el = document.createElement("button");
      el.type = "button";
      el.className = `orb orb-${target.color}`;
      el.style.left = `${target.x * 100}%`;
      el.style.top = `${target.y * 100}%`;
      el.style.setProperty("--life", `${target.lifetimeMs}ms`); // ring drain
      el.setAttribute("aria-label", target.isDecoy ? "avoid" : "target");
      if (target.seq != null) {
        const n = document.createElement("span");
        n.className = "orb-num";
        n.textContent = target.seq;
        el.appendChild(n);
      }
      arena.appendChild(el);

      // paint-aligned appearance timestamp
      requestAnimationFrame(() => {
        target.appearedAt = performance.now();
      });
      target.appearedAt = performance.now(); // fallback pre-rAF

      liveOrbs.set(target.id, { el, state: "live" });

      el.addEventListener("pointerdown", (e) => {
        e.stopPropagation();
        if (finished) return;
        const now = performance.now();
        result.pointerTypes.add(e.pointerType);

        if (target.isDecoy) {
          result.decoyTaps++;
          el.classList.remove("decoy-hit");
          void el.offsetWidth; // restart shake anim
          el.classList.add("decoy-hit");
          arena.classList.remove("flash");
          void arena.offsetWidth;
          arena.classList.add("flash");
          callbacks.onDecoy?.();
          return;
        }

        if (spec.type === "order" && target.seq !== expectedSeq) {
          result.wrongOrder++;
          el.classList.remove("decoy-hit");
          void el.offsetWidth;
          el.classList.add("decoy-hit");
          return;
        }
        if (spec.type === "order") expectedSeq++;

        const rt = Math.max(0, now - (target.appearedAt ?? now));
        result.hits.push({
          targetId: target.id,
          rt,
          tHit: now - t0,
          x: e.clientX,
          y: e.clientY,
          pt: e.pointerType,
        });
        chip(target.x * 100, target.y * 100, `${Math.round(rt)}ms`);
        burst(target.x * 100, target.y * 100, getComputedStyle(el).color);
        callbacks.onHit?.(rt);
        resolveTarget(target.id, "hit");
      });

      // expiry
      schedule(() => {
        if (!liveOrbs.has(target.id)) return;
        if (!target.isDecoy) {
          result.misses.push(target.id);
          callbacks.onMiss?.();
          resolveTarget(target.id, "expired");
        } else {
          resolveTarget(target.id, "expired", false);
        }
      }, target.lifetimeMs + 40);
    };

    // ---- schedule all appearances ----
    for (const target of spec.targets) {
      schedule(() => appear(target), target.appearAtMs);
    }

    // safety net — round hard-capped at last possible expiry + 2s
    const maxLife = Math.max(...spec.targets.map((t) => t.appearAtMs + t.lifetimeMs));
    schedule(finish, maxLife + 2000);
  });
}
