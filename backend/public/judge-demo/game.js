// NutriQuest judge demo — self-contained, no auth, no server writes.
// Mirrors spec constants: rarity/star combat mults, damage formula,
// crit 1/24, variance 0.85–1.0, per-move accuracy, Epic+ mana.

"use strict";

const RARITIES = ["common","uncommon","rare","epic","legendary","mythic","secret"];
const RARITY_MULT = { common:1, uncommon:1.06, rare:1.12, epic:1.25, legendary:1.4, mythic:1.55, secret:1.7 };
const STAR_MULT = { 1:1, 2:1.08, 3:1.18, 4:1.3, 5:1.45 };
const STAR_MANA = { 1:1, 2:1.1, 3:1.2, 4:1.35, 5:1.5 };
const BANDS = {
  common:[500,1099], uncommon:[1100,2649], rare:[2650,6899], epic:[6900,19499],
  legendary:[19500,58499], mythic:[58500,186999], secret:[187000,597999]
};
const MINT_SEGMENTS = [[0,.4,.55],[.4,.7,.27],[.7,.9,.13],[.9,.98,.04],[.98,1,.01]];
const SCAN_ODDS = { common:.80, uncommon:.16, rare:.032, epic:.0064,
  legendary:.00128, mythic:.000256, secret:.000064 };
const TILT = 0.8;
const DAMAGE_SCALE = 10, CRIT_CHANCE = 1/24, CRIT_MULT = 1.5;
const STATUS = { burn:.05, atkUp:1.25, guardUp:.7, accDown:.75, heal:.15, leech:.5, leechCap:.25 };

// Demo juice: real odds make legendaries near-impossible to see live.
// Judges get a generous demo table instead — every tier is reachable.
const DEMO_ODDS = { common:.40, uncommon:.25, rare:.16, epic:.10,
  legendary:.055, mythic:.028, secret:.007 };

const PRODUCTS = [
  ["Protein Bar", 72], ["Greek Yogurt", 80], ["Instant Noodles", 22],
  ["Salmon Fillet", 88], ["Granola", 55], ["Cola", 8], ["Kale Chips", 76],
  ["Chocolate Bar", 18], ["Quinoa Bowl", 83], ["Energy Drink", 12],
  ["Almonds", 78], ["Frozen Pizza", 25], ["Berry Smoothie", 70],
  ["Beef Jerky", 60], ["Avocado", 85], ["Candy Bag", 5], ["Oat Milk", 58],
  ["Sushi Roll", 66], ["Trail Mix", 62], ["Mystery Snack", 50]
];

const $ = (id) => document.getElementById(id);
const rnd = () => Math.random();

// ---------------- collection (localStorage) ----------------
let collection = JSON.parse(localStorage.getItem("nq_demo_collection") || "[]");
let coins = Number(localStorage.getItem("nq_demo_coins") || "1000");

function save() {
  localStorage.setItem("nq_demo_collection", JSON.stringify(collection));
  localStorage.setItem("nq_demo_coins", String(coins));
}
function eff(base, rarity, star) { return base * RARITY_MULT[rarity] * STAR_MULT[star]; }
function artURL(c, hurt) { return "/assets/" + (hurt ? c.hurt : c.art); }

// ---------------- scan / mint ----------------
function rollRarity(score) {
  const w = {};
  let total = 0;
  for (const r of RARITIES) {
    w[r] = DEMO_ODDS[r] * Math.exp(TILT * ((score - 50) / 50) * RARITIES.indexOf(r));
    total += w[r];
  }
  let roll = rnd() * total;
  for (const r of RARITIES) { roll -= w[r]; if (roll <= 0) return r; }
  return "common";
}
function rollNetWorth(rarity) {
  const [min, max] = BANDS[rarity];
  const width = max - min + 1;
  let roll = rnd(), acc = 0, seg = MINT_SEGMENTS[0];
  for (const s of MINT_SEGMENTS) { acc += s[2]; if (roll <= acc) { seg = s; break; } }
  return min + Math.floor(width * (seg[0] + (seg[1] - seg[0]) * rnd()));
}
function pickDesign(rarity) {
  const pool = CATALOG.filter(c => c.rarities.includes(rarity));
  return pool[Math.floor(rnd() * pool.length)];
}

function mint(score) {
  const rarity = rollRarity(score);
  const design = pickDesign(rarity);
  const netWorth = rollNetWorth(rarity);
  return { designId: design.id, rarity, star: 1, netWorth };
}

function tryFuse() {
  // 3 identical (design+rarity+star) -> next star. Secret caps at 2.
  const groups = {};
  for (const m of collection) {
    const k = `${m.designId}|${m.rarity}|${m.star}`;
    (groups[k] = groups[k] || []).push(m);
  }
  for (const k in groups) {
    const g = groups[k];
    const maxStar = g[0].rarity === "secret" ? 2 : 5;
    if (g.length >= 3 && g[0].star < maxStar) {
      const ids = new Set(g.slice(0, 3).map(m => m.uid));
      collection = collection.filter(m => !ids.has(m.uid));
      const upgraded = { ...g[0], star: g[0].star + 1, netWorth: g[0].netWorth * 2 };
      collection.push(upgraded);
      save();
      return upgraded;
    }
  }
  return null;
}

// ---------------- UI: tabs ----------------
document.querySelectorAll(".tab").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach(b => b.classList.toggle("active", b === btn));
    document.querySelectorAll(".panel").forEach(p => p.classList.toggle("active", p.id === "tab-" + btn.dataset.tab));
    if (btn.dataset.tab === "squad") renderCollection();
  });
});

function renderCoins() { $("coinCount").textContent = coins.toLocaleString(); }

// ---------------- UI: scan ----------------
let scanning = false;
$("scanBtn").addEventListener("click", () => {
  if (scanning) return;
  scanning = true;
  $("scanBtn").disabled = true;
  $("reveal").innerHTML = "";
  $("scanner").classList.add("scanning");
  $("scanHint").textContent = "";
  const [pname, score] = PRODUCTS[Math.floor(rnd() * PRODUCTS.length)];
  $("productLine").textContent = "…";
  setTimeout(() => {
    $("scanner").classList.remove("scanning");
    $("productLine").textContent = `${pname} — NutritionScore ${score}`;
    const m = mint(score);
    m.uid = Date.now() + "_" + Math.floor(rnd() * 1e6);
    collection.push(m);
    const fused = tryFuse();
    save();
    renderCoins();
    const c = CATALOG.find(x => x.id === m.designId);
    $("reveal").innerHTML = `
      <div class="reveal-card" style="--rc:var(--r-${m.rarity})">
        <img src="${artURL(c)}" alt="${c.name}">
        <div class="nm">${c.name}</div>
        <div class="rl">${m.rarity}</div>
        <div class="st">${"★".repeat(m.star)}</div>
        <div class="nw">Net worth ${m.netWorth.toLocaleString()} coins</div>
        <div class="nutri">${c.tagline}</div>
      </div>
      ${fused ? `<div class="fused">FUSED! ${c.name} is now ★${fused.star}</div>` : ""}`;
    $("scanBtn").disabled = false;
    scanning = false;
  }, 1200);
});

// ---------------- UI: squad ----------------
function renderCollection() {
  $("collectionCount").textContent = `${collection.length} monster${collection.length === 1 ? "" : "s"}`;
  $("netWorth").textContent = "Σ " + collection.reduce((a, m) => a + m.netWorth, 0).toLocaleString();
  const el = $("collection");
  if (!collection.length) {
    el.innerHTML = `<div class="note" style="grid-column:1/-1">Nothing yet. Scan a snack.</div>`;
    return;
  }
  const counts = {};
  for (const m of collection) counts[m.designId + m.star] = (counts[m.designId + m.star] || 0) + 1;
  const seen = {};
  el.innerHTML = collection
    .slice()
    .sort((a, b) => b.netWorth - a.netWorth)
    .map(m => {
      const c = CATALOG.find(x => x.id === m.designId);
      const key = m.designId + m.star;
      seen[key] = (seen[key] || 0) + 1;
      const total = counts[key];
      return `<div class="card" style="--rc:var(--r-${m.rarity})">
        ${total > 1 ? `<div class="cx">×${seen[key]}/${total}</div>` : ""}
        <img src="${artURL(c)}" alt="">
        <div class="cn">${c.name}</div>
        <div class="cs">${"★".repeat(m.star)}</div>
      </div>`;
    }).join("");
}

// ---------------- battle ----------------
function makeUnit(m) {
  const c = CATALOG.find(x => x.id === m.designId);
  const hasMana = ["epic","legendary","mythic","secret"].includes(m.rarity);
  return {
    c, rarity: m.rarity, star: m.star,
    maxHP: Math.round(eff(c.hp, m.rarity, m.star)),
    hp: Math.round(eff(c.hp, m.rarity, m.star)),
    mana: hasMana ? Math.floor(c.mana * STAR_MANA[m.star]) : 0,
    statuses: {},
    moves: hasMana && c.special ? [...c.moves, c.special] : c.moves
  };
}

let B = null; // battle state

$("fightBtn").addEventListener("click", () => {
  if (collection.length < 1) { $("battleSetup").querySelector(".note").textContent = "Scan a monster first."; return; }
  // Player squad: strongest 3 (or fewer).
  const mine = collection.slice().sort((a, b) => b.netWorth - a.netWorth).slice(0, 3).map(makeUnit);
  // Enemy squad: random designs, rarity near player's median.
  const medRarity = mine[Math.floor(mine.length / 2)].rarity;
  const medIdx = RARITIES.indexOf(medRarity);
  const enemy = [0, 1, 2].map(() => {
    const ri = Math.max(0, Math.min(6, medIdx + Math.floor(rnd() * 3) - 1));
    const r = RARITIES[ri];
    const pool = CATALOG.filter(c => c.rarities.includes(r));
    return makeUnit({ designId: pool[Math.floor(rnd() * pool.length)].id, rarity: r, star: 1 });
  });
  B = { me: mine, foe: enemy, ai: 0, fi: 0, over: false, turn: "player" };
  $("battleSetup").classList.add("hidden");
  $("arena").classList.remove("hidden");
  $("battleLog").innerHTML = "";
  renderBattle();
  log("Battle start — you go first.");
});

function renderBattle() {
  if (!B) return;
  const P = B.me[B.ai], E = B.foe[B.fi];
  $("playerImg").src = artURL(P.c); $("playerName").textContent = `${P.c.name} ★${P.star}`;
  $("enemyImg").src = artURL(E.c); $("enemyName").textContent = `${E.c.name} ★${E.star} (${E.rarity})`;
  $("playerHp").style.width = (100 * P.hp / P.maxHP) + "%";
  $("enemyHp").style.width = (100 * E.hp / E.maxHP) + "%";
  $("manaRow").textContent = P.mana > 0 || P.moves.some(m => m.mana > 0) ? `Mana ${P.mana}` : "";
  $("moves").innerHTML = "";
  P.moves.forEach((mv, i) => {
    const b = document.createElement("button");
    b.className = "move-btn" + (mv.mana > 0 ? " special" : "");
    b.innerHTML = `<span class="mn">${mv.name}</span><span class="mi">pow ${mv.power} · ${mv.acc}%${mv.mana ? ` · ${mv.mana} mana` : ""}${mv.status ? ` · ${mv.status}` : ""}</span>`;
    b.disabled = B.over || B.turn !== "player" || mv.mana > P.mana;
    b.addEventListener("click", () => takeTurn(i));
    $("moves").appendChild(b);
  });
  // benches
  $("enemySide").innerHTML = B.foe.map((u, i) =>
    `<div class="bench ${u.hp <= 0 ? "dead" : ""} ${i === B.fi ? "out" : ""}"><img src="${artURL(u.c)}"></div>`).join("");
  $("playerSide").innerHTML = B.me.map((u, i) =>
    `<div class="bench ${u.hp <= 0 ? "dead" : ""} ${i === B.ai ? "out" : ""}"><img src="${artURL(u.c)}"></div>`).join("");
}

function log(msg, cls) {
  const d = document.createElement("div");
  if (cls) d.className = cls;
  d.textContent = msg;
  const el = $("battleLog");
  el.appendChild(d);
  el.scrollTop = el.scrollHeight;
}
function floatDmg(id, text, crit) {
  const el = $(id);
  el.textContent = text;
  el.style.color = crit ? "#f0b429" : "#fff";
  el.classList.remove("show"); void el.offsetWidth; el.classList.add("show");
}
function shake(id) { const e = $(id); e.classList.remove("shake"); void e.offsetWidth; e.classList.add("shake"); }

function applyStatus(mv, atk, def, dmg) {
  if (!mv.status) return;
  if (rnd() * 100 >= (mv.statusChance || 100)) return;
  const s = mv.status;
  if (s === "heal") {
    const a = Math.round(atk.maxHP * STATUS.heal);
    atk.hp = Math.min(atk.maxHP, atk.hp + a);
    log(`${atk.c.name} heals ${a}.`);
  } else if (s === "leech") {
    const a = Math.round(Math.min(dmg * STATUS.leech, atk.maxHP * STATUS.leechCap));
    atk.hp = Math.min(atk.maxHP, atk.hp + a);
    log(`${atk.c.name} leeches ${a}.`);
  } else if (s === "atk_up" || s === "guard_up") {
    atk.statuses[s] = mv.dur || 2;
    log(`${atk.c.name}: ${s.replace("_", " ")}.`);
  } else {
    def.statuses[s] = mv.dur || 2;
    log(`${def.c.name}: ${s.replace("_", " ")}!`);
  }
}

function hit(atk, def, mv, dmgId, defId) {
  const acc = mv.acc * ((atk.statuses.acc_down || 0) > 0 ? STATUS.accDown : 1);
  if (rnd() * 100 >= acc) { log(`${atk.c.name}'s ${mv.name} missed.`); return; }
  let dmg = 0, crit = false;
  if (mv.power > 0) {
    crit = rnd() < CRIT_CHANCE;
    const variance = .85 + .15 * rnd();
    const ea = eff(atk.c.atk, atk.rarity, atk.star) * ((atk.statuses.atk_up || 0) > 0 ? STATUS.atkUp : 1);
    const gm = (def.statuses.guard_up || 0) > 0 ? STATUS.guardUp : 1;
    dmg = Math.max(1, Math.floor((mv.power * ea / DAMAGE_SCALE + 2) * (crit ? CRIT_MULT : 1) * variance * gm));
    def.hp = Math.max(0, def.hp - dmg);
    floatDmg(dmgId, (crit ? "CRIT " : "") + dmg, crit);
    shake(defId);
    log(`${atk.c.name} uses ${mv.name} — ${dmg} dmg${crit ? " CRIT!" : "."}`, crit ? "crit" : "");
  } else {
    log(`${atk.c.name} uses ${mv.name}.`);
  }
  applyStatus(mv, atk, def, dmg);
}

function tick(unit) {
  if ((unit.statuses.burn || 0) > 0) {
    const d = Math.max(1, Math.round(unit.maxHP * STATUS.burn));
    unit.hp = Math.max(0, unit.hp - d);
    log(`${unit.c.name} burns for ${d}.`);
  }
  for (const k in unit.statuses) if (--unit.statuses[k] <= 0) delete unit.statuses[k];
}

function alive(arr) { return arr.filter(u => u.hp > 0); }
function nextAlive(arr, i) { for (let j = i; j < arr.length; j++) if (arr[j].hp > 0) return j; return -1; }

function endCheck() {
  if (!alive(B.foe).length || !alive(B.me).length) {
    B.over = true;
    const win = alive(B.me).length > 0;
    const prize = win ? 250 : 0;
    if (win) { coins += prize; save(); renderCoins(); }
    log(win ? `You win! +${prize} coins.` : "Squad wiped.", win ? "crit" : "faint");
    const b = document.createElement("button");
    b.className = "big-btn"; b.textContent = "AGAIN";
    b.addEventListener("click", () => { $("arena").classList.add("hidden"); $("battleSetup").classList.remove("hidden"); });
    $("moves").innerHTML = "";
    $("moves").appendChild(b);
    renderBattle();
    return true;
  }
  return false;
}

function takeTurn(moveIdx) {
  if (!B || B.over || B.turn !== "player") return;
  B.turn = "anim";
  const P = B.me[B.ai], E = B.foe[B.fi];
  const mv = P.moves[moveIdx];
  P.mana -= mv.mana || 0;
  tick(P);
  if (P.hp <= 0) return afterFaint();
  if ((P.statuses.stun || 0) > 0) log(`${P.c.name} is stunned!`);
  else hit(P, E, mv, "enemyDmg", "enemyActive");
  renderBattle();
  if (endCheck()) return;
  if (E.hp <= 0) {
    log(`${E.c.name} fainted!`, "faint");
    B.fi = nextAlive(B.foe, B.fi + 1);
    renderBattle();
  }
  setTimeout(enemyTurn, 900);
}

function enemyTurn() {
  if (B.over) return;
  const P = B.me[B.ai], E = B.foe[B.fi];
  tick(E);
  if (E.hp <= 0) { afterFaint(); return; }
  if ((E.statuses.stun || 0) > 0) log(`${E.c.name} is stunned!`);
  else {
    const usable = E.moves.filter(m => (m.mana || 0) <= E.mana);
    const mv = usable[Math.floor(rnd() * usable.length)] || E.moves[0];
    E.mana -= mv.mana || 0;
    hit(E, P, mv, "playerDmg", "playerActive");
  }
  renderBattle();
  if (endCheck()) return;
  if (P.hp <= 0) { log(`${P.c.name} fainted!`, "faint"); afterFaint(); return; }
  B.turn = "player";
  renderBattle();
}

function afterFaint() {
  if (B.me[B.ai].hp <= 0) B.ai = nextAlive(B.me, B.ai + 1);
  if (B.foe[B.fi] && B.foe[B.fi].hp <= 0) B.fi = nextAlive(B.foe, B.fi + 1);
  if (!endCheck()) { B.turn = "player"; renderBattle(); }
}

// boot
renderCoins();
renderCollection();
