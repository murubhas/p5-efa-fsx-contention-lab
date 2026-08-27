#!/usr/bin/env node

// Visual and structural verification for the fifteen-minute demo deck.
//
// Read mode is a scrolling document, so it only has to avoid horizontal
// overflow. Present mode is the strict case: every chapter must fit the slide
// box after the deck's own auto-fit pass, because a presenter cannot scroll a
// slide that silently overflowed.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PAGE = path.resolve(
  __dirname,
  "..",
  "docs",
  "p5-efa-fsx-contention-15min-demo.html",
);
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const CHAPTERS = 14;
const SIZES = [
  [1920, 1080],
  [1600, 900],
  [1440, 900],
  [1366, 768],
];

const PROBE = String.raw`
(function () {
  function output(value) {
    document.documentElement.setAttribute(
      "data-deck-verify",
      encodeURIComponent(JSON.stringify(value))
    );
  }
  function run() {
    var killTransitions = document.createElement("style");
    killTransitions.textContent = "*{transition:none!important;animation:none!important}";
    document.head.appendChild(killTransitions);

    var params = new URLSearchParams(location.search);
    var theme = params.get("deckTheme") || "dark";
    document.documentElement.setAttribute("data-theme", theme);

    var duplicateIds = [];
    var seen = {};
    document.querySelectorAll("[id]").forEach(function (element) {
      if (seen[element.id]) duplicateIds.push(element.id);
      seen[element.id] = true;
    });

    var unnamed = [];
    document.querySelectorAll("button,a[href]").forEach(function (element) {
      var name = (element.getAttribute("aria-label") || element.textContent || "").trim();
      if (!name) unnamed.push(element.tagName + "#" + (element.id || "?"));
    });

    var external = [];
    document.querySelectorAll("script[src],link[href],img[src],image").forEach(function (element) {
      var value = element.getAttribute("src") || element.getAttribute("href") ||
                  element.getAttribute("xlink:href") || "";
      if (/^https?:|^\/\//.test(value)) external.push(value);
    });

    // any bar whose width or height escapes 0-100% means a hand-computed
    // percentage disagrees with its stated axis
    var badBars = [];
    document.querySelectorAll(".bar-fill,.vbar").forEach(function (element) {
      var raw = element.style.getPropertyValue("--w") || element.style.getPropertyValue("--h");
      var pct = parseFloat(raw);
      if (!(pct >= 0 && pct <= 100)) badBars.push(element.className + ":" + raw);
    });

    var readOverflowX = document.documentElement.scrollWidth - innerWidth;

    // present mode: walk every slide, let the deck auto-fit, then measure
    document.getElementById("presentMode").click();
    var slides = [];
    var chapters = [].slice.call(document.querySelectorAll(".chapter"));
    var links = [].slice.call(document.querySelectorAll(".chapter-link"));
    for (var i = 0; i < chapters.length; i += 1) {
      links[i].click();
      var chapter = chapters[i];
      var inner = chapter.querySelector(".chapter-inner");
      var styles = getComputedStyle(chapter);
      var available = chapter.clientHeight -
        parseFloat(styles.paddingTop) - parseFloat(styles.paddingBottom);
      slides.push({
        id: chapter.id,
        overflowing: chapter.classList.contains("overflowing"),
        fit: parseFloat(chapter.style.getPropertyValue("--fs-fit") || "1"),
        innerHeight: Math.round(inner.getBoundingClientRect().height),
        available: Math.round(available),
        overflowX: Math.round(inner.getBoundingClientRect().width - chapter.clientWidth),
      });
    }

    // figure zoom must clone without colliding ids against the live document
    var zoomIds = [];
    var firstFigure = document.querySelector("[data-zoom]");
    firstFigure.click();
    var zoomSeen = {};
    document.querySelectorAll("[id]").forEach(function (element) {
      if (zoomSeen[element.id]) zoomIds.push(element.id);
      zoomSeen[element.id] = true;
    });
    var zoomOpened = document.getElementById("zoom").classList.contains("open");
    document.getElementById("zoomClose").click();

    output({
      theme: theme,
      chapterCount: chapters.length,
      navCount: links.length,
      duplicateIds: duplicateIds,
      unnamed: unnamed,
      external: external,
      badBars: badBars,
      readOverflowX: readOverflowX,
      slides: slides,
      zoomOpened: zoomOpened,
      zoomDuplicateIds: zoomIds,
    });
  }
  if (document.readyState === "complete") setTimeout(run, 500);
  else addEventListener("load", function () { setTimeout(run, 500); });
})();
`;

async function probe(width, height, theme = "dark") {
  const source = await fs.readFile(PAGE, "utf8");
  const injected = source.replace("</body>", `<script>${PROBE}</script></body>`);
  const temporary = path.join(
    os.tmpdir(),
    `efa-fsx-deck-${width}x${height}-${theme}.html`,
  );
  await fs.writeFile(temporary, injected, "utf8");

  const args = [
    "--headless",
    "--disable-gpu",
    "--no-sandbox",
    "--hide-scrollbars",
    "--allow-file-access-from-files",
    "--enable-logging=stderr",
    "--v=0",
    "--virtual-time-budget=6000",
    `--window-size=${width},${height}`,
    "--dump-dom",
  ];
  args.push(`file://${temporary}?deckTheme=${theme}`);

  let combined = "";
  try {
    const result = await execFileAsync(CHROME, args, {
      maxBuffer: 64 * 1024 * 1024,
    });
    combined = `${result.stdout || ""}\n${result.stderr || ""}`;
  } catch (error) {
    combined = `${error.stdout || ""}\n${error.stderr || ""}`;
  }
  await fs.rm(temporary, { force: true });

  const marker = combined.match(/data-deck-verify="([^"]+)"/);
  if (!marker) {
    throw new Error(
      `Could not parse browser probe at ${width}x${height}:\n${combined.slice(-2500)}`,
    );
  }
  return JSON.parse(decodeURIComponent(marker[1].replace(/&amp;/g, "&")));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const pageStat = await fs.stat(PAGE);
assert(pageStat.size > 100_000, "Demo deck appears unexpectedly small");

let worstFit = 1;
for (const [width, height] of SIZES) {
  const result = await probe(width, height);
  const label = `${width}x${height}`;
  assert(result.chapterCount === CHAPTERS, `${label}: expected ${CHAPTERS} chapters, saw ${result.chapterCount}`);
  assert(result.navCount === CHAPTERS, `${label}: nav does not cover every chapter`);
  assert(result.duplicateIds.length === 0, `${label}: duplicate ids ${result.duplicateIds}`);
  assert(result.unnamed.length === 0, `${label}: unnamed controls ${result.unnamed}`);
  assert(result.external.length === 0, `${label}: external dependencies ${result.external}`);
  assert(result.badBars.length === 0, `${label}: bar out of 0-100% range ${result.badBars}`);
  assert(result.readOverflowX <= 1, `${label}: read mode overflows horizontally by ${result.readOverflowX}px`);
  assert(result.zoomOpened, `${label}: figure zoom did not open`);
  assert(result.zoomDuplicateIds.length === 0, `${label}: zoom clone collides on ids ${result.zoomDuplicateIds}`);

  const overflowing = result.slides.filter((s) => s.overflowing);
  assert(
    overflowing.length === 0,
    `${label}: present mode overflows on ${overflowing.map((s) => `${s.id} (${s.innerHeight} > ${s.available})`).join(", ")}`,
  );
  const wide = result.slides.filter((s) => s.overflowX > 1);
  assert(wide.length === 0, `${label}: present mode overflows horizontally on ${wide.map((s) => s.id)}`);

  const tightest = result.slides.reduce((a, b) => (a.fit <= b.fit ? a : b));
  worstFit = Math.min(worstFit, tightest.fit);
  const shrunk = result.slides.filter((s) => s.fit < 1).length;
  console.log(
    `PASS ${label} present-mode: ${result.slides.length} slides fit, ` +
    `${shrunk} auto-shrunk, tightest ${tightest.id} at ${tightest.fit.toFixed(3)}`,
  );
}

const light = await probe(1600, 900, "light");
assert(light.theme === "light", "Light theme was not applied");
assert(light.duplicateIds.length === 0, "light: duplicate ids");
assert(light.readOverflowX <= 1, "light: read mode overflows horizontally");
const lightOverflow = light.slides.filter((s) => s.overflowing);
assert(lightOverflow.length === 0, `light: present mode overflows on ${lightOverflow.map((s) => s.id)}`);
console.log("PASS light theme at 1600x900");

console.log(`VERIFIED ${PAGE} (tightest auto-fit across all viewports: ${worstFit.toFixed(3)})`);
